require "agentboard/container_sandbox"

module Agentboard
  # Runs provider agents inside OCI containers (security.sandbox: container, sandbox.agents: true).
  #
  # - The agent container is attached only to an *internal* network (no direct internet).
  #   Its single route out is the egress proxy container, which allowlists provider APIs.
  # - Mounts: the execution worktree and the repository's git directory, at their real host
  #   paths (so `git commit` works). Nothing else from the host is visible.
  # - Runs as the invoking UID, all capabilities dropped, no-new-privileges, CPU/memory/PID
  #   limits, read-only root filesystem with a tmpfs home.
  # - Credentials: only allowlisted variable *names* are forwarded (`-e NAME`), so values
  #   never appear in process listings.
  module AgentContainer
    DEFAULT_EGRESS = {
      "claude" => %w[api.anthropic.com:443 statsig.anthropic.com:443 sentry.io:443],
      "codex" => %w[api.openai.com:443 chatgpt.com:443 auth.openai.com:443],
      "fake" => []
    }.freeze
    PROXY_ALIAS = "agentboard-egress".freeze
    PROXY_PORT = 3128

    module_function

    def settings = ContainerSandbox.settings
    def runtime = settings["runtime"]
    def enabled? = ContainerSandbox.enabled? && settings["agents"] == true

    def image
      settings["agent_image"].presence or raise Error.validation_failed("sandbox.agent_image must be set to run agents in containers (see `agentboard sandbox build`)")
    end

    def project_id = Digest::SHA256.hexdigest(Agentboard.config.root_path.to_s)[0, 10]
    def network_name = "agentboard-#{project_id}-internal"
    def proxy_name = "agentboard-#{project_id}-egress"

    def egress_allowlist
      (DEFAULT_EGRESS.values.flatten + Array(settings["egress_allow"])).map(&:to_s).uniq.sort
    end

    # Builds the docker argv that wraps a provider LaunchSpec.
    def wrap(spec, execution:, name:)
      worktree = File.realpath(spec.chdir.to_s)
      git_common = git_common_dir(worktree)
      argv = [ runtime, "run", "--rm", "-i", "--init", "--name", name,
               "--label", "agentboard.execution=#{execution.id}",
               "--network", network_name,
               "--memory", settings["memory"].to_s, "--cpus", settings["cpus"].to_s, "--pids-limit", settings["pids_limit"].to_i.to_s,
               "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--read-only",
               "--tmpfs", "/tmp:rw,exec,size=1g", "--user", "#{::Process.uid}:#{::Process.gid}",
               "-v", "#{worktree}:#{worktree}:rw", "-v", "#{git_common}:#{git_common}:rw", "-w", worktree,
               "-e", "HOME=/tmp/agent-home", "-e", "AGENTBOARD_EXECUTION_ID=#{execution.id}", "-e", "AGENTBOARD_ISOLATION=container",
               "-e", "HTTPS_PROXY=http://#{PROXY_ALIAS}:#{PROXY_PORT}", "-e", "HTTP_PROXY=http://#{PROXY_ALIAS}:#{PROXY_PORT}",
               "-e", "NO_PROXY=localhost,127.0.0.1" ]
      if (dir = settings["claude_config_dir"].presence)
        FileUtils.mkdir_p(dir, mode: 0o700)
        argv += [ "-v", "#{File.realpath(dir)}:/tmp/agent-home/.claude:rw", "-e", "CLAUDE_CONFIG_DIR=/tmp/agent-home/.claude" ]
      end
      Array(spec.mounts).each { |m| real = File.realpath(m); argv += [ "-v", "#{real}:#{real}:ro" ] }
      spec.env.to_h.each { |k, v| argv += [ "-e", "#{k}=#{v}" ] if k.to_s.match?(/\A[A-Z_][A-Z0-9_]*\z/) && !secret_name?(k) }
      forwarded_credentials(spec).each { |k| argv += [ "-e", k ] }
      cli_env(spec).each_key { |k| argv += [ "-e", k ] unless argv.include?(k) }
      argv + [ image ] + spec.argv
    end

    # Names only; docker reads the values from its own environment.
    def forwarded_credentials(spec)
      allowed = Array(settings["credential_env"]).map(&:to_s)
      (Array(spec.passthrough_env).map(&:to_s) & (allowed.presence || Array(spec.passthrough_env).map(&:to_s))).select { |k| ENV[k].present? }
    end

    # Values for aliased credentials, placed in the docker CLI's own environment (never argv).
    def cli_env(spec)
      allowed = Array(settings["credential_env"]).map(&:to_s)
      Array(spec.credential_aliases).each_with_object({}) do |(name, source), env|
        next if allowed.any? && !allowed.include?(source.to_s)

        env[name.to_s] = ENV[source.to_s] if ENV[source.to_s].present?
      end
    end

    def secret_name?(name) = name.to_s.match?(/KEY|TOKEN|SECRET|PASSWORD/i)

    def git_common_dir(worktree)
      out, _e, st = Open3.capture3("git", "rev-parse", "--git-common-dir", chdir: worktree)
      raise Error.workspace_conflict("worktree has no git directory") unless st.success?

      File.realpath(File.expand_path(out.strip, worktree))
    end

    # Idempotently creates the internal network and the egress proxy container.
    def ensure_network!
      unless system(runtime, "network", "inspect", network_name, out: File::NULL, err: File::NULL)
        run!("network", "create", "--internal", "--label", "agentboard.project=#{project_id}", network_name)
      end
      allow = egress_allowlist.join(",")
      digest = Digest::SHA256.hexdigest(allow)[0, 12]
      out, _e, st = Open3.capture3(runtime, "inspect", "--format", "{{.State.Running}} {{index .Config.Labels \"agentboard.allow\"}}", proxy_name)
      running, label = out.split
      return if st.success? && running == "true" && label == digest

      Open3.capture3(runtime, "rm", "-f", proxy_name)
      proxy_script = File.expand_path("egress_proxy.rb", __dir__)
      run!("run", "-d", "--name", proxy_name, "--restart", "unless-stopped", "--label", "agentboard.allow=#{digest}",
           "--network", network_name, "--network-alias", PROXY_ALIAS, "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
           "--read-only", "--memory", "128m", "-e", "EGRESS_ALLOW=#{allow}",
           "-v", "#{proxy_script}:/egress_proxy.rb:ro", settings["proxy_image"].presence || "ruby:3.4-alpine", "ruby", "/egress_proxy.rb", PROXY_PORT.to_s)
      run!("network", "connect", "bridge", proxy_name)
    end

    def remove(name)
      Open3.capture3(runtime, "rm", "-f", name) if name.present?
    rescue StandardError
      nil
    end

    def run!(*args)
      out, err, st = Open3.capture3(runtime, *args)
      raise Error.provider_unavailable("#{runtime} #{args.first} failed: #{Redactor.redact(err.presence || out)[0, 300]}") unless st.success?

      out
    end
  end
end
