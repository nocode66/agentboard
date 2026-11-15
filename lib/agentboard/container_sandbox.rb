module Agentboard
  # OCI sandbox for verification commands (spec §14, §30.2, open decision #3).
  #
  #   security:
  #     sandbox: container
  #   sandbox:
  #     runtime: docker          # or podman
  #     image: my-app-ci:latest  # an image with the project's toolchain and gems
  #     network: none            # default-deny egress
  #     memory: 2g
  #     cpus: "2"
  #
  # The worktree is the only mount. The container runs as the invoking UID, with all
  # capabilities dropped, no-new-privileges and a PID limit. Paths are kept identical to the
  # host so Git metadata (worktree → common dir) resolves inside the container. Agent processes themselves are
  # not containerised in this release (they need provider binaries and credentials).
  module ContainerSandbox
    DEFAULTS = { "runtime" => "docker", "image" => nil, "network" => "none", "memory" => "2g", "cpus" => "2", "pids_limit" => 512,
                 "agents" => false, "agent_image" => nil, "proxy_image" => "ruby:3.4-alpine", "egress_allow" => [],
                 "credential_env" => [], "claude_config_dir" => nil }.freeze

    module_function

    def settings = DEFAULTS.merge(Agentboard.config.settings["sandbox"].to_h)
    def enabled? = Agentboard.config.security["sandbox"].to_s == "container"

    def available?
      out, _e, st = Open3.capture3(settings["runtime"], "info", "--format", "{{.ServerVersion}}")
      st.success? && out.strip.present?
    rescue Errno::ENOENT
      false
    end

    def container_name = "agentboard-#{SecureRandom.hex(6)}"

    # Wraps argv so it runs inside the sandbox with `workdir` mounted at /workspace.
    def wrap(argv, workdir:, env: {}, name: container_name)
      s = settings
      raise Error.validation_failed("sandbox.image must be configured for container verification") if s["image"].blank?
      raise Error.validation_failed("sandbox.network must be none or a named network") unless s["network"].to_s.match?(/\A[\w.-]+\z/)

      real = File.realpath(workdir.to_s)
      # Same absolute paths as on the host so git metadata resolves; the git dir is read-only.
      git_dir = begin
        out, _e, st = Open3.capture3("git", "rev-parse", "--git-common-dir", chdir: real)
        st.success? ? File.realpath(File.expand_path(out.strip, real)) : nil
      end
      cmd = [ s["runtime"], "run", "--rm", "--init", "--name", name,
              "--network", s["network"].to_s, "--memory", s["memory"].to_s, "--cpus", s["cpus"].to_s,
              "--pids-limit", s["pids_limit"].to_i.to_s, "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
              "--user", "#{::Process.uid}:#{::Process.gid}", "-v", "#{real}:#{real}" ]
      cmd += [ "-v", "#{git_dir}:#{git_dir}:ro" ] if git_dir && !git_dir.start_with?(real + "/")
      cmd += [ "-w", real, "-e", "HOME=/tmp" ]
      env.each { |k, v| cmd += [ "-e", "#{k}=#{v}" ] if k.to_s.match?(/\A[A-Z_][A-Z0-9_]*\z/) }
      cmd + [ s["image"].to_s ] + argv
    end

    # Best-effort removal after cancellation/timeout (killing the CLI may leave the container).
    def kill(name)
      Open3.capture3(settings["runtime"], "rm", "-f", name)
    rescue StandardError
      nil
    end
  end
end
