require "test_helper"

class SessionSecurityTest < ActiveSupport::TestCase
  test "MCP calls need the live session credential; humans can revoke a session" do
    t = create_ticket
    s = agent_session
    cred = Agentboard::SessionCredential.issue!(s)
    tools = Agentboard::McpTools.new(project: @project, session: s, credential: cred)
    claim = tools.call("claim_ticket", { "ticket_key" => "AB-1", "expected_version" => t.lock_version })
    assert claim.ok?

    forged = Agentboard::McpTools.new(project: @project, session: s, credential: Agentboard::SessionCredential::Credential.new(token: "x" * 40, expires_at: 1.hour.from_now))
    assert_equal "UNAUTHORIZED", forged.call("list_tickets", {}).error.code

    assert_error_code("FORBIDDEN") { Agentboard::SessionCredential.revoke!(s, actor: s.actor) }
    Agentboard::SessionCredential.revoke!(s, actor: human, reason: "test")
    res = tools.call("update_progress", { "ticket_key" => "AB-1", "lease_token" => claim.data[:lease_token], "message" => "still here?" })
    assert_equal "UNAUTHORIZED", res.error.code
    assert_equal 0, t.leases.live.count, "revocation releases the session's leases"
  end

  test "credentials rotate before they expire" do
    s = agent_session
    cred = Agentboard::SessionCredential.issue!(s)
    near = Agentboard::SessionCredential::Credential.new(token: cred.token, expires_at: 1.minute.from_now)
    rotated = Agentboard::SessionCredential.verify!(s, near)
    refute_equal cred.token, rotated.token
    assert_error_code("UNAUTHORIZED") { Agentboard::SessionCredential.verify!(s, cred) }
  end

  test "sessions of the same agent process are correlated and share the explicit ticket link" do
    t = create_ticket
    agent = Agentboard::ProcessAncestry::Agent.new(pid: 4242, command: "claude", fingerprint: "fp-1")
    mcp = agent_session(trust: "mcp_stdio")
    hook = agent_session(trust: "hook")
    Agentboard::SessionCorrelation.record_agent!(mcp, agent)
    Agentboard::SessionAssociation.link!(session: mcp, ticket: t, source: "mcp", actor: mcp.actor)
    Agentboard::SessionCorrelation.record_agent!(hook, agent)
    assert_equal mcp.id, hook.reload.metadata["correlated_session_id"]
    assert_equal t.id, hook.active_link&.ticket_id, "hook events now land on the ticket"
    other = agent_session(trust: "hook")
    Agentboard::SessionCorrelation.record_agent!(other, Agentboard::ProcessAncestry::Agent.new(pid: 4242, command: "claude", fingerprint: "reused-pid"))
    assert_nil other.reload.metadata["correlated_session_id"], "a reused PID with another fingerprint is not trusted"
  end

  test "process ancestry reads parent pid and command via ps" do
    ppid, comm = Agentboard::ProcessAncestry.info(Process.pid)
    assert_equal Process.ppid, ppid
    assert_match(/ruby/i, comm.to_s)
  end

  test "codex notify hook is opt-in, managed, preserved config and reversible" do
    home = Dir.mktmpdir("codex-home")
    File.write(File.join(home, "config.toml"), "model = \"x\"\n\n[mcp_servers.other]\ncommand = \"y\"\n")
    ENV["CODEX_HOME"] = home
    adapter = Agentboard::Providers::Codex.new(settings: {})
    change, backup = adapter.install_notify!(@repo_dir)
    assert_equal "added", change[:action]
    assert File.exist?(backup)
    content = File.read(File.join(home, "config.toml"))
    assert content.start_with?(Agentboard::Providers::ConfigEditor::MARK_BEGIN), "top-level key must precede tables"
    assert_includes content, "[mcp_servers.other]"
    assert Agentboard::Providers::ConfigEditor.remove_block!(File.join(home, "config.toml"))
    refute_includes File.read(File.join(home, "config.toml")), "agentboard"

    File.write(File.join(home, "config.toml"), "notify = [\"my-notifier\"]\n")
    change, = adapter.install_notify!(@repo_dir)
    assert_equal "skipped", change[:action], "never replaces a user's notify program"
  ensure
    ENV.delete("CODEX_HOME")
  end

  test "codex notify payloads arriving as argv are ingested" do
    raw = JSON.generate("type" => "agent-turn-complete", "thread-id" => "th-1", "turn-id" => "t1", "cwd" => @repo_dir, "last-assistant-message" => "Done")
    events = Agentboard::HookIngestion.ingest!(provider_key: "codex", event_name: "agent-turn-complete", raw: raw, project: @project)
    assert_equal "agent.session.turn_completed", events.first.event_type
    assert_equal "Done", events.first.data["summary"]
  end
end
