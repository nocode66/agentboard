require "test_helper"

class ProvidersTest < ActiveSupport::TestCase
  FIX = File.expand_path("../fixtures/providers", __dir__)

  def parse_all(adapter, file)
    File.readlines(File.join(FIX, file)).flat_map { |l| adapter.parse_event(raw_event: l) }
  end

  test "claude stream-json fixtures normalize, drop reasoning, report usage and denials" do
    events = parse_all(Agentboard::Providers::ClaudeCode.new(settings: {}), "claude_code/stream.jsonl")
    types = events.map(&:type)
    assert_equal "agent.session.started", types.first
    assert_equal "0b6c7f9e-1111-4a2b-9c3d-123456789abc", events.first.external_session_id
    assert_includes types, "agent.tool.started"
    assert_includes types, "agent.tool.completed"
    assert_includes types, "agent.execution.permission_denied"
    refute(events.any? { |e| e.payload.to_json.include?("private") }, "thinking must never be captured")
    result = events.find(&:terminal)
    assert_equal "succeeded", result.status
    usage = events.find(&:usage).usage
    assert_equal 1200, usage.input_tokens
    assert_equal 0.0123, usage.reported_cost
    assert_includes types, "agent.provider.unknown"
    assert_includes types, "agent.execution.output"
  end

  test "claude hook fixtures keep only documented low-sensitivity fields" do
    adapter = Agentboard::Providers::ClaudeCode.new(settings: {})
    hooks = JSON.parse(File.read(File.join(FIX, "claude_code/hooks.json")))
    start = adapter.parse_hook(event_name: "SessionStart", payload: hooks["session_start"]).first
    assert_equal "agent.session.started", start.type
    refute start.payload.key?("transcript_path")
    edit = adapter.parse_hook(event_name: "PreToolUse", payload: hooks["tool_start"]).first
    assert_equal "app/models/invoice.rb", edit.payload["target"]
    refute_includes edit.payload.to_json, "SECRET"
    assert_equal "agent.provider.unknown", adapter.parse_hook(event_name: "X", payload: hooks["unknown_event"]).first.type
  end

  test "codex exec --json fixtures normalize and never surface reasoning" do
    events = parse_all(Agentboard::Providers::Codex.new(settings: {}), "codex/exec.jsonl")
    assert_equal "0199a213-81c0-7800-8aa1-bbab2a035a53", events.first.external_session_id
    refute(events.any? { |e| e.payload.to_json.include?("Planning") })
    assert(events.any? { |e| e.type == "agent.tool.completed" && e.payload["files"] == [ "app/models/invoice.rb" ] })
    assert_equal 24763, events.find(&:usage).usage.input_tokens
    assert_equal "succeeded", events.find(&:terminal).status
    assert_equal "agent.provider.unknown", events.last.type
  end

  test "launch specs use argv arrays, stdin prompts and never unsafe flags" do
    t = create_ticket(title: "Title with $(rm -rf /) and `backticks`")
    e = Agentboard::Execution.new(ticket: t, provider_key: "claude", metadata: {}, agent_profile: Agentboard::AgentProfile.new(config: { "permission_mode" => "acceptEdits" }))
    spec = Agentboard::Providers::ClaudeCode.new(settings: {}).launch_spec(execution: e, worktree: "/tmp/wt", context_path: "/tmp/c.md", prompt: t.title)
    assert_kind_of Array, spec.argv
    refute_includes spec.argv, "--dangerously-skip-permissions"
    refute(spec.argv.any? { |a| a.include?("rm -rf") }, "ticket text goes through stdin, not argv")
    e.agent_profile.config = { "permission_mode" => "bypassPermissions" }
    assert_error_code("POLICY_DENIED") { Agentboard::Providers::ClaudeCode.new(settings: {}).launch_spec(execution: e, worktree: "/tmp", context_path: "x", prompt: "") }
    codex = Agentboard::Providers::Codex.new(settings: {}).launch_spec(execution: e.tap { _1.agent_profile.config = {} }, worktree: "/tmp/wt", context_path: "x", prompt: "p")
    assert_equal [ "codex", "exec", "--json", "--cd", "/tmp/wt", "--sandbox", "workspace-write", "--skip-git-repo-check", "-" ], codex.argv
  end

  test "third-party providers can register and must implement the contract" do
    custom = Class.new(Agentboard::Providers::Base) do
      def self.key = :custom_agent
      def probe(environment: ENV) = Agentboard::Providers::ProbeResult.new(provider: key, installed: true, supported_capabilities: [ :mcp ], diagnostics: [])
    end
    Agentboard.register_provider(:custom_agent, adapter: custom)
    assert Agentboard::Providers.registry.registered?(:custom_agent)
    assert_raises(Agentboard::UnsupportedCapability) { Agentboard::Providers.registry.fetch(:custom_agent).launch_spec(execution: nil, worktree: nil, context_path: nil, prompt: nil) }
    assert_raises(ArgumentError) { Agentboard.register_provider("Bad Key!", adapter: custom) }
  end

  test "claude passive setup is minimal, reversible and preserves existing config" do
    File.write(File.join(@repo_dir, ".mcp.json"), JSON.generate("mcpServers" => { "other" => { "command" => "x" } }))
    FileUtils.mkdir_p(File.join(@repo_dir, ".claude"))
    File.write(File.join(@repo_dir, ".claude/settings.local.json"), JSON.generate("permissions" => { "allow" => [ "Read" ] }))
    adapter = Agentboard::Providers::ClaudeCode.new(settings: {})
    result = adapter.install_passive_hooks(project: @project, root: @repo_dir)
    assert_equal 2, result.backups.size
    mcp = JSON.parse(File.read(File.join(@repo_dir, ".mcp.json")))
    assert mcp["mcpServers"]["other"]
    assert_includes mcp["mcpServers"]["agentboard"]["args"], "serve"
    settings = JSON.parse(File.read(File.join(@repo_dir, ".claude/settings.local.json")))
    assert_equal [ "Read" ], settings["permissions"]["allow"]
    assert_equal Agentboard::Providers::ClaudeCode::HOOK_EVENTS.sort, settings["hooks"].keys.sort
    adapter.install_passive_hooks(project: @project, root: @repo_dir) # idempotent
    assert_equal 1, JSON.parse(File.read(File.join(@repo_dir, ".claude/settings.local.json")))["hooks"]["Stop"].size

    adapter.remove_passive_hooks(project: @project, root: @repo_dir)
    mcp = JSON.parse(File.read(File.join(@repo_dir, ".mcp.json")))
    assert_equal [ "other" ], mcp["mcpServers"].keys
    settings = JSON.parse(File.read(File.join(@repo_dir, ".claude/settings.local.json")))
    assert_nil settings["hooks"]
    assert_equal [ "Read" ], settings["permissions"]["allow"]
  end
end

class HookIngestionTest < ActiveSupport::TestCase
  test "hooks create corroborated sessions, deduplicate replays and redact" do
    raw = JSON.generate("session_id" => "s-1", "hook_event_name" => "PreToolUse", "tool_name" => "Bash",
                        "tool_input" => { "command" => "export TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789" })
    first = Agentboard::HookIngestion.ingest!(provider_key: "claude", event_name: "PreToolUse", raw: raw, project: @project)
    again = Agentboard::HookIngestion.ingest!(provider_key: "claude", event_name: "PreToolUse", raw: raw, project: @project)
    assert_equal first.map(&:id), again.map(&:id), "replayed hook event is deduplicated"
    session = Agentboard::AgentSession.find_by!(external_session_id: "s-1")
    assert_equal "hook", session.trust_level
    refute_includes first.first.payload.to_json, "ghp_"
    assert_equal "provider_reported", first.first.provenance
  end

  test "branch heuristic links need confirmation and never override explicit links" do
    t = create_ticket
    other = create_ticket(title: "other")
    git!("checkout", "-q", "-b", "feature/AB-1-totals")
    Agentboard::HookIngestion.ingest!(provider_key: "claude", event_name: "SessionStart",
                                      raw: JSON.generate("session_id" => "s-2", "hook_event_name" => "SessionStart", "cwd" => @repo_dir), project: @project)
    session = Agentboard::AgentSession.find_by!(external_session_id: "s-2")
    link = session.active_link
    assert_equal t.id, link.ticket_id
    assert_equal "needs_confirmation", link.confidence

    Agentboard::SessionAssociation.link!(session: session, ticket: other, source: "cli_attach", actor: human)
    assert_error_code("POLICY_DENIED") { Agentboard::SessionAssociation.link!(session: session, ticket: t, source: "branch_heuristic", actor: system_actor) }
    assert_equal other.id, session.reload.active_link.ticket_id
  end

  test "malformed and oversized payloads are rejected; spool replays later" do
    assert_error_code("VALIDATION_FAILED") { Agentboard::HookIngestion.ingest!(provider_key: "claude", event_name: "Stop", raw: "{nope", project: @project) }
    assert_error_code("VALIDATION_FAILED") { Agentboard::HookIngestion.ingest!(provider_key: "claude", event_name: "Stop", raw: "x" * 300_000, project: @project) }
    Agentboard::HookIngestion.spool!(root: @repo_dir, provider_key: "claude", event_name: "Stop", raw: JSON.generate("session_id" => "s-9", "hook_event_name" => "Stop"))
    assert_equal 1, Agentboard::HookIngestion.replay_spool!(root: @repo_dir)
    assert Agentboard::AgentSession.exists?(external_session_id: "s-9")
  end
end

# Contract tests against sanitized output captured from real, pinned provider versions.
class RealProviderFixturesTest < ActiveSupport::TestCase
  FIX = File.expand_path("../fixtures/providers", __dir__)

  test "Claude Code 2.1.325 real stream: tool use, result, usage and new event types" do
    adapter = Agentboard::Providers::ClaudeCode.new(settings: {})
    events = File.readlines(File.join(FIX, "claude_code/real_2.1.325_stream.jsonl")).flat_map { |l| adapter.parse_event(raw_event: l) }
    assert_equal "agent.session.started", events.first.type
    assert(events.any? { |e| e.type == "agent.tool.started" && e.payload["tool"] == "Write" && e.payload["target"] == "/workspace/HELLO.md" })
    assert(events.any? { |e| e.type == "agent.tool.completed" && e.payload["ok"] })
    assert_includes events.map(&:type), "agent.provider.unknown", "rate_limit_event is labeled, not dropped silently"
    result = events.find(&:terminal)
    assert_equal "succeeded", result.status
    usage = events.find(&:usage).usage
    assert_equal 189, usage.output_tokens
    assert_equal 0.00302497, usage.reported_cost
    assert_equal "USD", usage.currency
  end

  test "Codex 0.156.1 real failure stream maps to a failed terminal result" do
    adapter = Agentboard::Providers::Codex.new(settings: {})
    events = File.readlines(File.join(FIX, "codex/real_0.156.1_model_rejected.jsonl")).flat_map { |l| adapter.parse_event(raw_event: l) }
    assert_equal "00000000-0000-7000-8000-000000000002", events.first.external_session_id
    assert(events.any? { |e| e.type == "agent.execution.error" && e.payload["message"].include?("model_not_found") })
    terminal = events.find(&:terminal)
    assert_equal "failed", terminal.status
    refute(events.any? { |e| e.type == "agent.provider.unknown" }, "every real event type is understood")
  end
end
