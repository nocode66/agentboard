# Allowlisting HTTP CONNECT proxy for containerised agents. Runs inside the egress container
# (attached to the internal agent network and to the default bridge) — or in-process in
# tests. Only CONNECT to allowlisted host:port pairs is permitted; plain HTTP is refused.
#
#   EGRESS_ALLOW="api.anthropic.com:443,api.openai.com:443" ruby egress_proxy.rb [port]
require "socket"
require "json"
require "time"

module Agentboard
  class EgressProxy
    attr_reader :port

    def initialize(allow:, port: 3128, bind: "0.0.0.0", log: $stdout)
      @allow = Array(allow).map { |a| a.to_s.downcase.strip }.reject(&:empty?).to_h { |a| h, p = a.split(":", 2); [ "#{h}:#{p || 443}", true ] }
      @server = TCPServer.new(bind, port)
      @port = @server.addr[1]
      @log = log
      @running = true
    end

    def allowed?(host, port) = @allow.key?("#{host.to_s.downcase}:#{port.to_i}")

    def serve
      while @running
        client = @server.accept
        Thread.new(client) { |c| handle(c) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def start = (@thread = Thread.new { serve }; self)

    def stop
      @running = false
      @server.close
    rescue IOError
      nil
    end

    private

    def handle(client)
      line = client.gets.to_s
      method, target, = line.split(" ", 3)
      while (h = client.gets) && h != "\r\n"; end # drain headers
      host, port = target.to_s.split(":", 2)
      if method != "CONNECT" || host.to_s.empty?
        log("denied", method: method, target: target, reason: "only CONNECT is allowed")
        return client.write("HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n")
      end
      unless allowed?(host, port || 443)
        log("denied", target: target, reason: "not in allowlist")
        return client.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n")
      end

      upstream = Socket.tcp(host, (port || 443).to_i, connect_timeout: 10)
      client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
      log("allowed", target: target)
      pipe(client, upstream)
    rescue StandardError => e
      log("error", target: target, reason: e.class.name)
      client.write("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n") rescue nil
    ensure
      client.close rescue nil
      upstream&.close rescue nil
    end

    def pipe(a, b)
      loop do
        ready, = IO.select([ a, b ], nil, nil, 300)
        break unless ready

        ready.each do |io|
          data = io.read_nonblock(65_536, exception: false)
          next if data == :wait_readable
          return if data.nil?

          (io == a ? b : a).write(data)
        end
      end
    end

    def log(decision, **fields)
      @log&.puts(JSON.generate({ ts: Time.now.utc.iso8601, component: "egress", decision: decision }.merge(fields)))
      @log&.flush
    end
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  Agentboard::EgressProxy.new(allow: ENV.fetch("EGRESS_ALLOW", "").split(","), port: (ARGV[0] || 3128).to_i).serve
end
