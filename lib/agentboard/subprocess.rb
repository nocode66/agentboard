module Agentboard
  # Safe subprocess spawning shared by verification and provider launches.
  #
  # - argv arrays only (no shell, no interpolation of ticket text)
  # - own process group so cancellation reaches every child
  # - scrubbed environment (allowlist) to avoid leaking credentials
  # - continuous draining with a byte cap; truncation is marked, never silent
  module Subprocess
    ENV_ALLOWLIST = %w[PATH HOME USER LOGNAME SHELL LANG LC_ALL LC_CTYPE TERM TMPDIR TZ
                       RBENV_VERSION RBENV_ROOT MISE_DATA_DIR MISE_CONFIG_DIR ASDF_DIR ASDF_DATA_DIR
                       GEM_HOME GEM_PATH BUNDLE_PATH BUNDLE_GEMFILE RUBYOPT RUBYLIB
                       NODE_PATH XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME SSL_CERT_FILE].freeze

    Result = Struct.new(:exit_code, :signal, :timed_out, :cancelled, :duration, :output, :truncated, keyword_init: true) do
      def success? = exit_code == 0 && !timed_out && !cancelled
    end

    module_function

    def scrubbed_env(extra = {}, passthrough: [])
      base = ENV.to_h.slice(*(ENV_ALLOWLIST + Array(passthrough)))
      base.merge(extra.transform_keys(&:to_s).transform_values(&:to_s))
    end

    # Spawns argv; yields each output chunk (already redacted) if a block is given.
    # Returns a handle hash { pid:, pgid:, reader: }.
    def spawn(argv, chdir:, env: {}, passthrough_env: [], stdin_data: nil)
      raise ArgumentError, "argv must be a non-empty Array" unless argv.is_a?(Array) && argv.any?
      raise ArgumentError, "argv elements must be strings" unless argv.all? { |a| a.is_a?(String) }

      reader, writer = IO.pipe
      in_r, in_w = IO.pipe
      pid = ::Process.spawn(scrubbed_env(env, passthrough: passthrough_env), *argv,
                            chdir: chdir.to_s, pgroup: true, in: in_r, out: writer, err: writer,
                            unsetenv_others: true, close_others: true)
      writer.close
      in_r.close
      if stdin_data
        Thread.new do
          in_w.write(stdin_data)
        rescue IOError, Errno::EPIPE
          nil
        ensure
          in_w.close unless in_w.closed?
        end
      else
        in_w.close
      end
      { pid: pid, pgid: pid, reader: reader }
    end

    # Runs to completion with timeout/cancellation. `cancel_check` is polled.
    def run(argv, chdir:, timeout:, env: {}, max_bytes: 1_000_000, grace: 5, cancel_check: nil, log_io: nil, passthrough_env: [], stdin_data: nil, &on_chunk)
      started = monotonic
      handle = spawn(argv, chdir: chdir, env: env, passthrough_env: passthrough_env, stdin_data: stdin_data)
      buffer = +""
      truncated = false
      timed_out = false
      cancelled = false
      reader = handle[:reader]

      loop do
        if timeout && monotonic - started > timeout
          timed_out = true
          terminate(handle[:pgid], grace: grace)
          break
        end
        if cancel_check&.call
          cancelled = true
          terminate(handle[:pgid], grace: grace)
          break
        end
        ready = IO.select([ reader ], nil, nil, 0.2)
        next unless ready

        begin
          chunk = reader.read_nonblock(16_384)
        rescue IO::WaitReadable
          next
        rescue EOFError
          break
        end
        chunk = Redactor.redact(chunk.force_encoding("UTF-8").scrub)
        log_io&.write(chunk)
        on_chunk&.call(chunk)
        if buffer.bytesize < max_bytes
          buffer << chunk.byteslice(0, max_bytes - buffer.bytesize)
        else
          truncated = true
        end
      end
      reader.close unless reader.closed?
      _, status = ::Process.wait2(handle[:pid])
      Result.new(exit_code: status.exitstatus, signal: status.termsig, timed_out: timed_out, cancelled: cancelled,
                 duration: monotonic - started, output: truncated ? buffer + "\n[agentboard: output truncated at #{max_bytes} bytes]\n" : buffer,
                 truncated: truncated)
    rescue Errno::ENOENT => e
      Result.new(exit_code: 127, signal: nil, timed_out: false, cancelled: false, duration: 0, output: "command not found: #{argv.first} (#{e.class})", truncated: false)
    end

    # Graceful SIGTERM to the process group, SIGKILL after grace period.
    def terminate(pgid, grace: 5)
      signal_group("TERM", pgid)
      deadline = monotonic + grace
      while monotonic < deadline
        return true unless group_alive?(pgid)

        sleep 0.05
      end
      signal_group("KILL", pgid)
      true
    end

    def signal_group(sig, pgid)
      ::Process.kill(sig, -pgid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def group_alive?(pgid)
      ::Process.kill(0, -pgid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def alive?(pid)
      ::Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # Best-effort process identity: start time + command, used to avoid trusting reused PIDs.
    def fingerprint(pid)
      out, _e, st = Open3.capture3("ps", "-o", "lstart=,command=", "-p", pid.to_s)
      st.success? ? Digest::SHA256.hexdigest(out.strip)[0, 32] : nil
    rescue StandardError
      nil
    end

    # Resource usage of a whole process group: { rss_kb:, cpu_seconds:, processes: }.
    # `ps -A -o pid,pgid,rss,time` works on both macOS (BSD ps) and Linux (procps).
    def group_usage(pgid)
      out, _e, st = Open3.capture3("ps", "-A", "-o", "pgid=,rss=,time=")
      return nil unless st.success?

      rows = out.lines.map(&:split).select { |r| r[0].to_i == pgid.to_i }
      { rss_kb: rows.sum { |r| r[1].to_i }, cpu_seconds: rows.sum { |r| parse_cpu_time(r[2]) }.round(2), processes: rows.size }
    rescue StandardError
      nil
    end

    # Accepts [[dd-]hh:]mm:ss[.xx]
    def parse_cpu_time(str)
      days, rest = str.to_s.include?("-") ? str.split("-", 2) : [ 0, str.to_s ]
      parts = rest.split(":").map(&:to_f)
      parts.unshift(0) while parts.size < 3
      days.to_i * 86_400 + parts[0] * 3600 + parts[1] * 60 + parts[2]
    end

    def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
