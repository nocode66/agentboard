module Agentboard
  module Providers
    # OpenAI Codex adapter.
    #
    # Passive: registers the MCP server through Codex's own interface
    # (`codex mcp add agentboard -- bundle exec agentboard mcp serve --root ROOT`), so
    # AgentBoard never rewrites ~/.codex/config.toml. Codex exposes no general lifecycle
    # hooks to AgentBoard here, so passive tracking relies on explicit MCP activity and Git
    # observation, labeled with provenance. MCP alone is not comprehensive tracking.
    #
    # Active: `codex exec --json --cd WORKTREE --sandbox workspace-write -` with the prompt
    # on stdin. The App Server protocol is deliberately not used until fixture-backed tests
    # exist for a pinned version (spec §26.3).
    class Codex < Base
      SANDBOXES = %w[read-only workspace-write].freeze

      def self.key = :codex
      def self.display_name = "OpenAI Codex"
      def self.binary = "codex"

      def probe(environment: ENV)
        path = which("codex")
        return ProbeResult.new(provider: key, installed: false, supported_capabilities: [], validation: "not installed",
                               diagnostics: [ "`codex` binary not found on PATH" ]) unless path

        version = run_version([ path, "--version" ]).to_s[/\d+\.\d+\.\d+/]
        all = %i[mcp active_execution structured_events streaming cancellation session_resume]
        caps, validation, diags = negotiate(version, all, safe_caps: %i[mcp])
        ProbeResult.new(provider: key, installed: true, version: version, authenticated: nil, supported_capabilities: caps,
                        validation: validation,
                        diagnostics: diags + [ "Passive tracking for Codex is limited to MCP activity and Git observation." ])
      end

      def mcp_command(root:) = [ "bundle", "exec", "agentboard", "mcp", "serve", "--root", root.to_s ]

      def config_toml_path = File.join(ENV.fetch("CODEX_HOME", File.join(Dir.home, ".codex")), "config.toml")

      # Codex calls the `notify` program with a JSON argument after each agent turn. It is a
      # global, top-level key, so AgentBoard only adds it when explicitly requested and when no
      # other notify program is configured; the managed block is removed by `provider remove`.
      def notify_command(root)
        [ "/usr/bin/env", "BUNDLE_GEMFILE=#{File.join(root, "Gemfile")}", RbConfig.ruby, "-rbundler/setup",
          File.expand_path("../../../exe/agentboard", __dir__), "hook", "ingest", "--provider", "codex", "--event", "agent-turn-complete", "--root", root.to_s ]
      end

      def install_notify!(root)
        path = config_toml_path
        content = File.exist?(path) ? File.read(path) : ""
        top_level = content.split(/^\s*\[/, 2).first.to_s
        if top_level.match?(/^\s*notify\s*=/) && !content.include?(ConfigEditor::MARK_BEGIN)
          return [ { path: path, action: "skipped", reason: "an existing notify program is configured" }, nil ]
        end

        backup = ConfigEditor.backup!(path)
        change = ConfigEditor.upsert_block!(path, "notify = #{JSON.generate(notify_command(root))}", position: :start)
        [ change, backup ]
      end

      def install_passive_hooks(project:, root:, notify: false)
        path = which("codex") or raise Error.provider_unavailable("codex binary not found")
        list_out, _e, _s = Open3.capture3(Subprocess.scrubbed_env, path, "mcp", "list")
        if list_out.to_s.match?(/^\s*agentboard\b/)
          changes = [ { path: "codex mcp", keys: [ "agentboard" ], action: "unchanged" } ]
        else
          out, err, st = Open3.capture3(Subprocess.scrubbed_env, path, "mcp", "add", "agentboard", "--", *mcp_command(root: root))
          raise Error.provider_unavailable("codex mcp add failed: #{Redactor.redact(err.presence || out)[0, 300]}") unless st.success?

          changes = [ { path: "codex mcp", keys: [ "agentboard" ], action: "added", command: mcp_command(root: root).join(" ") } ]
        end
        backups = []
        warnings = []
        if notify
          change, backup = install_notify!(root)
          changes << change
          backups << backup if backup
        else
          warnings << "Codex notify hook not installed (pass --notify); activity is tracked through MCP calls and Git evidence."
        end
        manifest = { "provider" => key, "codex_mcp_name" => "agentboard", "notify_config" => (notify ? config_toml_path : nil) }.compact
        ConfigEditor.write_manifest!(root, key, manifest)
        SetupResult.new(provider: key, changes: changes, manifest: manifest, backups: backups, warnings: warnings)
      end

      def remove_passive_hooks(project:, root:, manifest: nil)
        removed = []
        manifest ||= ConfigEditor.read_manifest(root, key) || {}
        removed << manifest["notify_config"] if manifest["notify_config"] && ConfigEditor.remove_block!(manifest["notify_config"])
        if (path = which("codex"))
          _o, _e, st = Open3.capture3(Subprocess.scrubbed_env, path, "mcp", "remove", "agentboard")
          removed << "codex mcp agentboard" if st.success?
        end
        removed
      end

      # Hook-style payloads (e.g. from a `notify` program) are accepted if an operator wires one.
      def parse_hook(event_name:, payload:)
        data = payload.is_a?(Hash) ? payload : {}
        type = data["type"] == "agent-turn-complete" ? "agent.session.turn_completed" : "agent.provider.unknown"
        summary = data["last-assistant-message"].to_s[0, 500].presence
        [ NormalizedEvent.build(type, { "cwd" => data["cwd"], "turn_id" => data["turn-id"], "summary" => summary }.compact,
                                external_session_id: data["thread-id"]) ]
      end

      def launch_spec(execution:, worktree:, context_path:, prompt:)
        config = execution.agent_profile&.config || {}
        container = execution.metadata["isolation"] == "container"
        # Codex's own sandbox (Seatbelt/Landlock) is unavailable inside Docker; the container is the boundary.
        sandbox = config.fetch("sandbox", container ? "danger-full-access" : "workspace-write").to_s
        allowed = container ? SANDBOXES + %w[danger-full-access] : SANDBOXES
        raise Error.policy_denied("Codex sandbox #{sandbox} is not allowed#{" outside a container" unless container}") unless allowed.include?(sandbox)

        argv = [ "codex", "exec", "--json", "--cd", worktree.to_s, "--sandbox", sandbox, "--skip-git-repo-check" ]
        argv += [ "--model", config["model"].to_s ] if config["model"].to_s.match?(/\A[\w.\-:]+\z/)
        argv << "-"
        # `codex exec` authenticates API keys via CODEX_API_KEY; map it from OPENAI_API_KEY.
        LaunchSpec.new(argv: argv, env: {}, stdin_data: prompt, chdir: worktree, passthrough_env: %w[OPENAI_API_KEY CODEX_API_KEY CODEX_HOME],
                       credential_aliases: container ? { "CODEX_API_KEY" => "OPENAI_API_KEY" } : nil)
      end

      def resume_spec(execution:, worktree:, input:)
        tid = execution.metadata["provider_session_id"].to_s
        raise UnsupportedCapability.new(:session_resume, provider: key) unless tid.match?(/\A[\w-]{8,}\z/) && supports?(:session_resume)

        LaunchSpec.new(argv: [ "codex", "exec", "--json", "--cd", worktree.to_s, "resume", tid, "-" ], env: {}, stdin_data: input.to_s,
                       chdir: worktree, passthrough_env: %w[OPENAI_API_KEY CODEX_HOME])
      end

      def parse_event(raw_event:)
        data = safe_json(raw_event)
        return [ NormalizedEvent.build("agent.execution.output", { "text" => raw_event.to_s.chomp[0, 4000] }) ] unless data.is_a?(Hash)

        case data["type"]
        when "thread.started" then [ NormalizedEvent.build("agent.session.started", {}, external_session_id: data["thread_id"]) ]
        when "turn.started" then [ NormalizedEvent.build("agent.execution.turn_started", {}) ]
        when "item.started", "item.updated", "item.completed" then parse_item(data)
        when "turn.completed"
          u = data["usage"].is_a?(Hash) ? data["usage"] : {}
          [ NormalizedEvent.build("agent.execution.usage", u.slice("input_tokens", "cached_input_tokens", "output_tokens"),
                                  usage: Usage.new(input_tokens: u["input_tokens"], output_tokens: u["output_tokens"], metering_kind: "unknown")),
            NormalizedEvent.build("agent.execution.result", { "ok" => true }, terminal: true, status: "succeeded") ]
        when "turn.failed"
          [ NormalizedEvent.build("agent.execution.result", { "ok" => false, "error" => data.dig("error", "message").to_s[0, 2000] }, terminal: true, status: "failed") ]
        when "error"
          [ NormalizedEvent.build("agent.execution.error", { "message" => data["message"].to_s[0, 2000] }) ]
        else
          [ NormalizedEvent.build("agent.provider.unknown", { "raw_type" => data["type"].to_s[0, 64] }) ]
        end
      end

      private

      def parse_item(data)
        item = data["item"].is_a?(Hash) ? data["item"] : {}
        done = data["type"] == "item.completed"
        case item["type"]
        when "agent_message"
          done ? [ NormalizedEvent.build("agent.execution.message", { "text" => item["text"].to_s[0, 8000] }) ] : []
        when "reasoning" then [] # private model reasoning is never surfaced
        when "command_execution"
          payload = { "tool" => "shell", "command_excerpt" => item["command"].to_s[0, 160], "exit_code" => item["exit_code"], "status" => item["status"] }.compact
          [ NormalizedEvent.build(done ? "agent.tool.completed" : "agent.tool.started", payload) ]
        when "file_change"
          files = Array(item["changes"]).map { |c| c["path"].to_s[0, 300] }.first(50)
          [ NormalizedEvent.build("agent.tool.completed", { "tool" => "file_change", "files" => files, "status" => item["status"] }.compact) ]
        when "mcp_tool_call"
          [ NormalizedEvent.build(done ? "agent.tool.completed" : "agent.tool.started", { "tool" => "mcp:#{item["server"]}/#{item["tool"]}" }) ]
        when "error"
          done ? [ NormalizedEvent.build("agent.execution.error", { "message" => item["message"].to_s[0, 2000] }) ] : []
        when "todo_list", "web_search"
          [ NormalizedEvent.build("agent.execution.activity", { "kind" => item["type"] }) ]
        else
          [ NormalizedEvent.build("agent.provider.unknown", { "raw_type" => "item:#{item["type"]}".to_s[0, 64] }) ]
        end
      end
    end
  end
end
