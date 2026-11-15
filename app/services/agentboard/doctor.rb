module Agentboard
  # Diagnostics shared by `agentboard doctor` and the Settings page (spec §31.3).
  class Doctor
    Check = Struct.new(:name, :status, :detail, keyword_init: true) # status: ok | warn | fail

    def initialize(root:)
      @root = root.to_s
    end

    def checks
      [ ruby_check, git_check, worktree_check, database_check, migrations_check, mount_check, config_check,
        daemon_check, mcp_check, sandbox_check, edition_check, *Extensions.run(:doctor_checks).flatten.compact, *provider_checks ]
    end

    def ok? = checks.none? { |c| c.status == "fail" }

    private

    def edition_check
      ext = Extensions.extensions.values
      if ext.empty?
        Check.new(name: "Edition", status: "ok", detail: "Community (MIT) — Pro features: #{Extensions::FEATURES.keys.join(", ")}")
      else
        Check.new(name: "Edition", status: "ok", detail: ext.map { |e| "#{e.name} #{e.version} (#{e.enabled_features.join(", ").presence || "no licensed features"})" }.join("; "))
      end
    end

    def ruby_check
      ok = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.3")
      Check.new(name: "Ruby", status: ok ? "ok" : "fail", detail: "#{RUBY_VERSION} (requires >= 3.3)")
    end

    def git_check
      out, _e, st = Open3.capture3("git", "--version")
      repo = Git::Repository.new(@root)
      return Check.new(name: "Git", status: "fail", detail: "git not available") unless st.success?
      return Check.new(name: "Git", status: "fail", detail: "#{@root} is not a Git repository") unless repo.repository?

      Check.new(name: "Git", status: "ok", detail: "#{out.strip} · default branch #{repo.default_branch}")
    rescue Errno::ENOENT
      Check.new(name: "Git", status: "fail", detail: "git not found on PATH")
    end

    def worktree_check
      out, _e, st = Open3.capture3("git", "worktree", "list", chdir: @root)
      Check.new(name: "Git worktrees", status: st.success? ? "ok" : "fail", detail: st.success? ? "#{out.lines.size} worktree(s)" : "git worktree unsupported")
    rescue Errno::ENOENT
      Check.new(name: "Git worktrees", status: "fail", detail: "git not found")
    end

    def database_check
      adapter = ActiveRecord::Base.connection_db_config.adapter
      status = adapter.include?("postgres") ? "ok" : "warn"
      detail = adapter.include?("sqlite") ? "#{adapter} — single-user development mode (PostgreSQL recommended for concurrent leases)" : adapter
      Check.new(name: "Database", status: status, detail: detail)
    rescue StandardError => e
      Check.new(name: "Database", status: "fail", detail: e.class.name)
    end

    def migrations_check
      missing = %w[agentboard_tickets agentboard_executions agentboard_events].reject { |t| ActiveRecord::Base.connection.table_exists?(t) }
      if missing.any?
        Check.new(name: "Migrations", status: "fail", detail: "missing tables: #{missing.join(", ")} — run bin/rails db:migrate")
      else
        Check.new(name: "Migrations", status: "ok", detail: "AgentBoard tables present")
      end
    rescue StandardError => e
      Check.new(name: "Migrations", status: "fail", detail: e.class.name)
    end

    def mount_check
      mounted = Rails.application.routes.routes.any? { |r| r.app.respond_to?(:app) && r.app.app == Agentboard::Engine }
      Check.new(name: "Dashboard mount", status: mounted ? "ok" : "warn",
                detail: mounted ? "mounted (development only by default)" : "Agentboard::Engine is not mounted in config/routes.rb")
    rescue StandardError
      Check.new(name: "Dashboard mount", status: "warn", detail: "could not inspect routes")
    end

    def config_check
      files = Agentboard.config.loaded_files
      Check.new(name: "Configuration", status: files.any? ? "ok" : "warn",
                detail: files.any? ? files.map { |f| f.delete_prefix(@root + "/") }.join(", ") : "no config file found — run `agentboard init`")
    end

    def daemon_check
      st = Runtime::DaemonControl.status
      if st[:running]
        Check.new(name: "Runtime daemon", status: "ok", detail: "pid #{st[:pid]}, #{st.dig(:health, "active")} active")
      else
        Check.new(name: "Runtime daemon", status: "warn", detail: st[:stale_pid_file] ? "stale PID file; daemon not running" : "not running — `agentboard daemon start`")
      end
    end

    def mcp_check
      require "mcp"
      Check.new(name: "MCP server", status: "ok", detail: "mcp gem #{Gem.loaded_specs["mcp"]&.version} · stdio transport")
    rescue LoadError
      Check.new(name: "MCP server", status: "fail", detail: "mcp gem not available")
    end

    def sandbox_check
      sec = Agentboard.config.security
      if AgentContainer.enabled?
        return Check.new(name: "Execution isolation", status: "fail", detail: "sandbox.agents is on but #{AgentContainer.runtime} is not running") unless ContainerSandbox.available?
        return Check.new(name: "Execution isolation", status: "fail", detail: "sandbox.agent_image is not set (agentboard sandbox build)") if ContainerSandbox.settings["agent_image"].blank?

        return Check.new(name: "Execution isolation", status: "ok",
                         detail: "agents in containers (#{ContainerSandbox.settings["agent_image"]}), internal network, egress: #{AgentContainer.egress_allowlist.size} allowed endpoints")
      end
      if sec["trusted_local_execution"] && sec["sandbox"] != "container"
        Check.new(name: "Execution isolation", status: "warn", detail: "trusted local subprocesses (worktrees are not sandboxes)")
      elsif sec["sandbox"] == "container"
        if ContainerSandbox.available?
          Check.new(name: "Execution isolation", status: "ok", detail: "verification runs in #{ContainerSandbox.settings["runtime"]} (network #{ContainerSandbox.settings["network"]}); agents require trusted_local_execution")
        else
          Check.new(name: "Execution isolation", status: "fail", detail: "sandbox: container but #{ContainerSandbox.settings["runtime"]} is not running")
        end
      else
        Check.new(name: "Execution isolation", status: "ok", detail: "active execution of real agents disabled until trusted_local_execution is enabled")
      end
    end

    def provider_checks
      Providers.registry.all.reject { |p| p.key == "fake" }.map do |p|
        probe = p.probe
        status = !probe.installed ? "warn" : (probe.supports?(:active_execution) ? "ok" : "warn")
        caps = probe.supported_capabilities.map(&:to_s).join(", ")
        Check.new(name: "Provider: #{p.display_name}", status: status,
                  detail: probe.installed ? "#{probe.version} · #{probe.validation} · #{caps.presence || "no capabilities"}" : "not installed")
      end
    end
  end
end
