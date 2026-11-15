require "socket"

module Agentboard
  module Runtime
    # Local runtime IPC (spec §27.2): Unix domain socket in a user-private directory (0700),
    # socket file 0600, plus a per-daemon bearer token (0600) checked on every request.
    # Frames are 4-byte big-endian length + JSON, with a protocol version and size limit.
    module IPC
      PROTOCOL_VERSION = 1
      MAX_MESSAGE_BYTES = 1024 * 1024

      module_function

      def paths(config = Agentboard.config)
        dir = config.runtime_dir
        id = Digest::SHA256.hexdigest(config.root_path.to_s)[0, 12]
        { dir: dir, socket: dir.join("#{id}.sock"), token: dir.join("#{id}.token"), pid: dir.join("#{id}.pid"), log: dir.join("#{id}.log") }
      end

      def ensure_private_dir!(dir)
        FileUtils.mkdir_p(dir, mode: 0o700)
        stat = File.stat(dir)
        raise Error.forbidden("Runtime directory #{dir} is not owned by the current user") unless stat.owned?

        File.chmod(0o700, dir)
      end

      def write_frame(io, obj)
        data = JSON.generate(obj)
        raise Error.validation_failed("IPC message too large") if data.bytesize > MAX_MESSAGE_BYTES

        io.write([ data.bytesize ].pack("N") + data)
      end

      def read_frame(io, timeout: 10)
        header = read_exact(io, 4, timeout)
        return nil unless header

        size = header.unpack1("N")
        raise Error.validation_failed("IPC message too large") if size > MAX_MESSAGE_BYTES

        JSON.parse(read_exact(io, size, timeout) || raise(Error.validation_failed("truncated IPC frame")))
      end

      def read_exact(io, n, timeout)
        buf = +""
        while buf.bytesize < n
          return nil unless IO.select([ io ], nil, nil, timeout)

          chunk = io.read_nonblock(n - buf.bytesize, exception: false)
          return nil if chunk.nil?
          next if chunk == :wait_readable

          buf << chunk
        end
        buf
      end

      class Server
        def initialize(handler:, config: Agentboard.config, logger: Agentboard.logger)
          @handler = handler
          @paths = IPC.paths(config)
          @logger = logger
          @running = false
        end

        def start
          IPC.ensure_private_dir!(@paths[:dir])
          File.delete(@paths[:socket]) if File.socket?(@paths[:socket])
          @token = Ids.token
          File.write(@paths[:token], @token, perm: 0o600)
          File.chmod(0o600, @paths[:token])
          old = File.umask(0o177)
          @server = UNIXServer.new(@paths[:socket].to_s)
          File.umask(old)
          File.chmod(0o600, @paths[:socket])
          @running = true
          @thread = Thread.new { accept_loop }
          self
        end

        def stop
          @running = false
          @server&.close
          File.delete(@paths[:socket]) if File.socket?(@paths[:socket])
          File.delete(@paths[:token]) if File.exist?(@paths[:token])
        rescue SystemCallError, IOError
          nil
        end

        private

        def accept_loop
          while @running
            client = @server.accept
            Thread.new(client) { |c| serve(c) }
          end
        rescue IOError, Errno::EBADF
          nil
        end

        def serve(client)
          request = IPC.read_frame(client)
          return unless request

          response = dispatch(request)
          IPC.write_frame(client, response)
        rescue StandardError => e
          IPC.write_frame(client, { "ok" => false, "error" => { "code" => "INTERNAL_ERROR", "message" => e.class.name } }) rescue nil
        ensure
          client.close
        end

        def dispatch(request)
          unless request["protocol"] == PROTOCOL_VERSION
            return { "ok" => false, "error" => { "code" => "VALIDATION_FAILED", "message" => "unsupported protocol #{request["protocol"].inspect}" } }
          end
          presented = request["token"].to_s
          unless presented.bytesize == @token.bytesize && OpenSSL.fixed_length_secure_compare(presented, @token)
            @logger.warn("[agentboard] rejected unauthenticated IPC request")
            return { "ok" => false, "error" => { "code" => "UNAUTHORIZED", "message" => "invalid runtime credential" } }
          end

          result = Result.capture(correlation_id: request["correlation_id"].presence || Ids.correlation) do
            @handler.call(request["op"].to_s, request["params"] || {})
          end
          JSON.parse(result.to_json)
        end
      end

      class Client
        def initialize(config: Agentboard.config)
          @paths = IPC.paths(config)
        end

        def available? = File.socket?(@paths[:socket]) && File.exist?(@paths[:token])

        def call(op, params = {}, timeout: 30)
          raise Error.provider_unavailable("Runtime daemon is not running (agentboard daemon start)") unless available?

          token = File.read(@paths[:token]).strip
          UNIXSocket.open(@paths[:socket].to_s) do |sock|
            IPC.write_frame(sock, { "protocol" => PROTOCOL_VERSION, "op" => op, "params" => params, "token" => token, "correlation_id" => Ids.correlation })
            IPC.read_frame(sock, timeout: timeout) || raise(Error.provider_unavailable("No response from runtime"))
          end
        rescue Errno::ECONNREFUSED, Errno::ENOENT
          raise Error.provider_unavailable("Runtime daemon is not reachable")
        end
      end
    end

    # Daemon lifecycle helpers: PID record with liveness validation (never trust a PID file alone).
    module DaemonControl
      module_function

      def status(config = Agentboard.config)
        paths = IPC.paths(config)
        pid = File.exist?(paths[:pid]) ? File.read(paths[:pid]).to_i : nil
        alive = pid && pid.positive? && Subprocess.alive?(pid)
        health = nil
        if alive && IPC::Client.new(config: config).available?
          response = IPC::Client.new(config: config).call("runtime.health", {}, timeout: 3) rescue nil
          health = response && response["ok"] ? response["data"] : nil
        end
        { running: !!(alive && health), pid: alive ? pid : nil, stale_pid_file: pid && !alive, health: health, socket: paths[:socket].to_s, log: paths[:log].to_s }
      end

      def write_pid!(config = Agentboard.config)
        paths = IPC.paths(config)
        IPC.ensure_private_dir!(paths[:dir])
        lock = File.open(paths[:pid], File::RDWR | File::CREAT, 0o600)
        raise Error.workspace_conflict("Another AgentBoard daemon is running for this project") unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        lock.truncate(0)
        lock.write(::Process.pid.to_s)
        lock.flush
        lock # keep open to hold the lock for the daemon lifetime
      end

      def stop(config = Agentboard.config, timeout: 20)
        st = status(config)
        return false unless st[:pid]

        ::Process.kill("TERM", st[:pid])
        deadline = Subprocess.monotonic + timeout
        sleep 0.1 while Subprocess.alive?(st[:pid]) && Subprocess.monotonic < deadline
        !Subprocess.alive?(st[:pid])
      rescue Errno::ESRCH
        true
      end
    end
  end
end
