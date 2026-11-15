module Agentboard
  module Providers
    # Claude Code adapter.
    #
    # Passive: registers the AgentBoard MCP server in the project's `.mcp.json` and installs
    # lifecycle hooks in `.claude/settings.local.json` (git-ignored by Claude Code), each
    # running `agentboard hook ingest --provider claude --event <Event>`.
    #
    # Active: `claude -p --output-format stream-json --verbose` in the worktree with the
    # prompt on stdin. Never enables `--dangerously-skip-permissions`; permission mode
    # defaults to `acceptEdits` (file edits allowed, shell tools denied in print mode).
    #
    # Flags were checked against `claude --help` for the versions listed in
    # compatibility/claude.yml. Hook payload fields follow Claude Code's documented hook input.
    class ClaudeCode < Base
      HOOK_EVENTS = %w[SessionStart UserPromptSubmit PreToolUse PostToolUse Notification Stop SubagentStop SessionEnd].freeze
      HOOK_EVENT_MAP = {
        "SessionStart" => "agent.session.started",
        "UserPromptSubmit" => "agent.session.prompt_submitted",
        "PreToolUse" => "agent.tool.started",
        "PostToolUse" => "agent.tool.completed",
        "Notification" => "agent.session.notification",
        "Stop" => "agent.session.turn_completed",
        "SubagentStop" => "agent.session.subagent_completed",
        "SessionEnd" => "agent.session.ended"
      }.freeze
      # Only documented, low-sensitivity fields are retained from hook input.
      HOOK_FIELDS = %w[session_id hook_event_name cwd tool_name source reason message stop_hook_active permission_mode].freeze
      PERMISSION_MODES = %w[default acceptEdits plan].freeze

      def self.key = :claude
      def self.display_name = "Claude Code"
      def self.binary = "claude"

      def probe(environment: ENV)
        path = which("claude")
        return ProbeResult.new(provider: key, installed: false, supported_capabilities: [], validation: "not installed",
                               diagnostics: [ "`claude` binary not found on PATH" ]) unless path

        raw = run_version([ path, "--version" ])
        version = raw.to_s[/\d+\.\d+\.\d+/]
        all = %i[mcp passive_hooks active_execution structured_events streaming cancellation session_resume permission_requests]
        caps, validation, diags = negotiate(version, all, safe_caps: %i[mcp passive_hooks])
        ProbeResult.new(provider: key, installed: true, version: version, authenticated: nil,
                        supported_capabilities: caps, validation: validation,
                        diagnostics: diags + [ "Authentication is managed by Claude Code and is not inspected by AgentBoard." ])
      end

      # -- passive ---------------------------------------------------------------------
      def mcp_entry(root:)
        { "command" => "bundle", "args" => [ "exec", "agentboard", "mcp", "serve", "--root", root.to_s ], "env" => {} }
      end

      def hook_command(event)
        %(cd "$CLAUDE_PROJECT_DIR" && bundle exec agentboard hook ingest --provider claude --event #{event})
      end

      def install_passive_hooks(project:, root:)
        mcp_path = File.join(root, ".mcp.json")
        settings_path = File.join(root, ".claude", "settings.local.json")
        backups = [ ConfigEditor.backup!(mcp_path), ConfigEditor.backup!(settings_path) ].compact
        changes = []

        changes << ConfigEditor.merge_json!(mcp_path, %w[mcpServers agentboard], mcp_entry(root: root),
                                            owned: ->(e) { e.is_a?(Hash) && Array(e["args"]).include?("agentboard") })

        settings = ConfigEditor.read_json(settings_path)
        settings["hooks"] ||= {}
        added = []
        HOOK_EVENTS.each do |event|
          groups = (settings["hooks"][event] ||= [])
          command = hook_command(event)
          next if groups.any? { |g| Array(g["hooks"]).any? { |h| h["command"].to_s.include?("agentboard hook ingest") } }

          groups << { "matcher" => "", "hooks" => [ { "type" => "command", "command" => command, "timeout" => 10 } ] }
          added << event
        end
        ConfigEditor.write_json(settings_path, settings) if added.any?
        changes << { path: settings_path, keys: [ "hooks" ], action: added.any? ? "added" : "unchanged", events: added }

        manifest = { "provider" => key, "mcp" => { "path" => mcp_path, "keys" => %w[mcpServers agentboard] },
                     "hooks" => { "path" => settings_path, "events" => HOOK_EVENTS } }
        ConfigEditor.write_manifest!(root, key, manifest)
        SetupResult.new(provider: key, changes: changes, manifest: manifest, backups: backups, warnings: [])
      end

      def remove_passive_hooks(project:, root:, manifest: nil)
        manifest ||= ConfigEditor.read_manifest(root, key) || {}
        removed = []
        if (m = manifest["mcp"]) && ConfigEditor.delete_json!(m["path"], m["keys"])
          removed << m["path"]
        end
        if (h = manifest["hooks"]) && File.exist?(h["path"])
          settings = ConfigEditor.read_json(h["path"])
          (settings["hooks"] || {}).each_value do |groups|
            groups.each { |g| g["hooks"] = Array(g["hooks"]).reject { |x| x["command"].to_s.include?("agentboard hook ingest") } }
            groups.reject! { |g| g["hooks"].empty? }
          end
          settings["hooks"]&.reject! { |_k, v| v.empty? }
          settings.delete("hooks") if settings["hooks"] && settings["hooks"].empty?
          ConfigEditor.write_json(h["path"], settings)
          removed << h["path"]
        end
        removed
      end

      def parse_hook(event_name:, payload:)
        data = payload.is_a?(Hash) ? payload : {}
        name = data["hook_event_name"].presence || event_name.to_s
        type = HOOK_EVENT_MAP.fetch(name, "agent.provider.unknown")
        kept = data.slice(*HOOK_FIELDS)
        if (input = data["tool_input"]).is_a?(Hash)
          # Keep a target path for traceability; never retain full tool input (may hold secrets).
          kept["target"] = (input["file_path"] || input["path"] || input["notebook_path"]).to_s[0, 500].presence
          kept["command_excerpt"] = input["command"].to_s[0, 120].presence if data["tool_name"] == "Bash"
        end
        [ NormalizedEvent.build(type, kept.compact, external_session_id: data["session_id"]) ]
      end

      # -- active ----------------------------------------------------------------------
      def launch_spec(execution:, worktree:, context_path:, prompt:)
        config = execution.agent_profile&.config || {}
        container = execution.metadata["isolation"] == "container"
        # Inside the container the container is the security boundary (no host access, egress
        # allowlist), so the agent may use tools without prompts. On the host it never can.
        mode = config.fetch("permission_mode", container ? "bypassPermissions" : "acceptEdits").to_s
        allowed_modes = container ? PERMISSION_MODES + %w[bypassPermissions] : PERMISSION_MODES
        raise Error.policy_denied("Permission mode #{mode} is not allowed#{" outside a container" unless container}") unless allowed_modes.include?(mode)

        argv = [ "claude", "-p", "--output-format", "stream-json", "--verbose", "--permission-mode", mode ]
        argv += [ "--model", config["model"].to_s ] if config["model"].to_s.match?(/\A[\w.\-:]+\z/)
        allowed = Array(config["allowed_tools"]).map(&:to_s).grep(/\A[\w()*:,. \-\/]+\z/)
        argv += [ "--allowedTools", *allowed ] if allowed.any?
        env = {}
        if config.fetch("interactive_permissions", true) && !container
          # Permission prompts are answered by a human through AgentBoard approvals: Claude calls
          # the execution-bound AgentBoard MCP server, which blocks until a decision is made.
          argv += [ "--mcp-config", JSON.generate("mcpServers" => { "agentboard" => permission_bridge(execution) }),
                    "--strict-mcp-config", "--permission-prompt-tool", "mcp__agentboard__permission_prompt" ]
          env["MCP_TOOL_TIMEOUT"] = ((Agentboard.config.runtime.fetch("permission_timeout_seconds", 600).to_i + 30) * 1000).to_s
        end
        LaunchSpec.new(argv: argv, env: env, stdin_data: prompt, chdir: worktree,
                       passthrough_env: %w[ANTHROPIC_API_KEY CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CONFIG_DIR])
      end

      def permission_bridge(execution)
        root = Agentboard.config.root_path.to_s
        { "command" => RbConfig.ruby,
          "args" => [ File.expand_path("../../../exe/agentboard", __dir__), "mcp", "serve", "--root", root, "--execution", execution.id, "--provider", "claude" ],
          "env" => { "BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "RUBYOPT" => "-rbundler/setup", "RAILS_ENV" => ENV.fetch("RAILS_ENV", "development") } }
      end

      def resume_spec(execution:, worktree:, input:)
        sid = execution.metadata["provider_session_id"].to_s
        raise UnsupportedCapability.new(:session_resume, provider: key) unless sid.match?(/\A[\w-]{8,}\z/) && supports?(:session_resume)

        argv = [ "claude", "-p", "--output-format", "stream-json", "--verbose", "--resume", sid, "--permission-mode", "acceptEdits" ]
        env = {}
        if (execution.agent_profile&.config || {}).fetch("interactive_permissions", true)
          argv += [ "--mcp-config", JSON.generate("mcpServers" => { "agentboard" => permission_bridge(execution) }),
                    "--strict-mcp-config", "--permission-prompt-tool", "mcp__agentboard__permission_prompt" ]
          env["MCP_TOOL_TIMEOUT"] = ((Agentboard.config.runtime.fetch("permission_timeout_seconds", 600).to_i + 30) * 1000).to_s
        end
        LaunchSpec.new(argv: argv, env: env, stdin_data: input.to_s, chdir: worktree, passthrough_env: %w[ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR])
      end

      def parse_event(raw_event:)
        data = safe_json(raw_event)
        return [ NormalizedEvent.build("agent.execution.output", { "text" => raw_event.to_s.chomp[0, 4000] }) ] unless data.is_a?(Hash)

        sid = data["session_id"]
        case data["type"]
        when "system"
          if data["subtype"] == "init"
            [ NormalizedEvent.build("agent.session.started", { "model" => data["model"], "cwd" => data["cwd"], "tools_count" => Array(data["tools"]).size }, external_session_id: sid) ]
          else
            [ NormalizedEvent.build("agent.provider.system", { "subtype" => data["subtype"].to_s[0, 64] }, external_session_id: sid) ]
          end
        when "assistant"
          Array(data.dig("message", "content")).filter_map do |block|
            case block["type"]
            when "text" then NormalizedEvent.build("agent.execution.message", { "text" => block["text"].to_s[0, 8000] }, external_session_id: sid)
            when "tool_use"
              input = block["input"].is_a?(Hash) ? block["input"] : {}
              NormalizedEvent.build("agent.tool.started", { "tool" => block["name"], "tool_use_id" => block["id"],
                                                            "target" => (input["file_path"] || input["path"]).to_s[0, 500].presence }.compact, external_session_id: sid)
            end
            # "thinking" blocks are intentionally dropped: AgentBoard does not expose model reasoning.
          end
        when "user"
          Array(data.dig("message", "content")).filter_map do |block|
            next unless block["type"] == "tool_result"

            NormalizedEvent.build("agent.tool.completed", { "tool_use_id" => block["tool_use_id"], "ok" => !block["is_error"] }, external_session_id: sid)
          end
        when "result"
          usage = data["usage"].is_a?(Hash) ? data["usage"] : {}
          events = []
          Array(data["permission_denials"]).first(20).each do |d|
            events << NormalizedEvent.build("agent.execution.permission_denied", { "tool" => d["tool_name"].to_s[0, 64] }, external_session_id: sid)
          end
          events << NormalizedEvent.build("agent.execution.usage", { "input_tokens" => usage["input_tokens"], "output_tokens" => usage["output_tokens"],
                                                                    "reported_cost" => data["total_cost_usd"], "currency" => (data["total_cost_usd"] ? "USD" : nil),
                                                                    "num_turns" => data["num_turns"] }.compact,
                                          external_session_id: sid,
                                          usage: Usage.new(input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"],
                                                           reported_cost: data["total_cost_usd"], currency: data["total_cost_usd"] ? "USD" : nil,
                                                           metering_kind: "unknown"))
          ok = data["subtype"] == "success" && !data["is_error"]
          events << NormalizedEvent.build("agent.execution.result", { "ok" => ok, "subtype" => data["subtype"], "summary" => data["result"].to_s[0, 4000] },
                                          external_session_id: sid, terminal: true, status: ok ? "succeeded" : "failed")
          events
        else
          [ NormalizedEvent.build("agent.provider.unknown", { "raw_type" => data["type"].to_s[0, 64] }, external_session_id: sid) ]
        end
      end
    end
  end
end
