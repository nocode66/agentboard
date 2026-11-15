require "test_helper"

class McpToolsTest < ActiveSupport::TestCase
  def tools_for(session) = Agentboard::McpTools.new(project: @project, session: session, credential: Agentboard::SessionCredential.issue!(session))

  test "AT-02/AT-03: an agent claims, starts, reports progress and submits for review via MCP" do
    t = create_ticket
    session = agent_session(provider: "codex")
    tools = tools_for(session)

    nxt = tools.call("get_next_ticket", {})
    assert nxt.ok?
    assert_equal "AB-1", nxt.data[:ticket][:key]

    claim = tools.call("claim_ticket", { "ticket_key" => "AB-1", "expected_version" => nxt.data[:ticket][:version] })
    assert claim.ok?, claim.to_h.inspect
    token = claim.data[:lease_token]
    refute Agentboard::TicketLease.exists?(token_digest: token), "only the digest is stored"

    assert tools.call("start_work", { "ticket_key" => "AB-1", "lease_token" => token }).ok?
    assert_equal "in_progress", t.reload.status
    assert_equal t.id, session.reload.active_ticket.id

    prog = tools.call("update_progress", { "ticket_key" => "AB-1", "lease_token" => token, "message" => "halfway", "percent" => 50 })
    assert prog.ok?
    assert_equal "provider_reported", Agentboard::Event.find(prog.data[:event_id]).provenance

    sha = commit_file!("invoice_total.rb", "def total; end")
    denied = tools.call("submit_for_review", { "ticket_key" => "AB-1", "lease_token" => token, "head_sha" => sha })
    refute denied.ok?
    assert_equal "POLICY_DENIED", denied.error.code, "checks have not run for this head yet"

    Agentboard::VerificationService.verify_repository!(ticket: t, actor: human)
    review = tools.call("submit_for_review", { "ticket_key" => "AB-1", "lease_token" => token, "head_sha" => sha, "summary" => "done" })
    assert review.ok?, review.to_h.inspect
    assert_equal "review", t.reload.status

    done = tools.call("complete_ticket", { "ticket_key" => "AB-1", "expected_version" => t.lock_version, "lease_token" => token })
    refute done.ok?
    assert_equal "POLICY_DENIED", done.error.code, "agents cannot bypass human approval"
  end

  test "another MCP session cannot use a stolen lease token" do
    create_ticket
    owner = tools_for(agent_session)
    thief = tools_for(agent_session)
    token = owner.call("claim_ticket", { "ticket_key" => "AB-1", "expected_version" => 1 }).data&.dig(:lease_token) ||
            owner.call("claim_ticket", { "ticket_key" => "AB-1", "expected_version" => Agentboard::Ticket.first.lock_version }).data[:lease_token]
    res = thief.call("update_progress", { "ticket_key" => "AB-1", "lease_token" => token, "message" => "hijack" })
    assert_equal "UNAUTHORIZED", res.error.code
    assert Agentboard::Event.where(event_type: "security.mcp_denied").exists?
  end

  test "claiming with a stale version returns VERSION_CONFLICT; second claim LEASE_CONFLICT" do
    t = create_ticket
    a = tools_for(agent_session)
    b = tools_for(agent_session)
    assert_equal "VERSION_CONFLICT", a.call("claim_ticket", { "ticket_key" => "AB-1", "expected_version" => 999 }).error.code
    assert a.call("claim_ticket", { "ticket_key" => "AB-1", "expected_version" => t.reload.lock_version }).ok?
    assert_equal "LEASE_CONFLICT", b.call("claim_ticket", { "ticket_key" => "AB-1", "expected_version" => t.reload.lock_version }).error.code
  end

  test "tools are scoped to the project and never leak internals" do
    other = Agentboard::Project.create!(name: "Other", key: "ZZ", root_path: "/tmp/zz-#{SecureRandom.hex(2)}", default_branch: "main")
    Agentboard::Tickets.create!(project: other, actor: human, title: "secret project", criteria: [ "x" ], status: "ready")
    res = tools_for(agent_session).call("get_ticket", { "ticket_key" => "ZZ-1" })
    assert_equal "NOT_FOUND", res.error.code
    res = tools_for(agent_session).call("get_project_context", { "paths" => [ "../../etc/passwd", "README.md" ] })
    assert res.ok?
    assert_equal [ "README.md" ], res.data[:context][:files].map { |f| f[:path] }
  end

  test "complete_ticket rejects fabricated evidence ids" do
    create_ticket
    res = tools_for(agent_session).call("complete_ticket", { "ticket_key" => "AB-1", "expected_version" => 1, "evidence_ids" => [ "forged" ] })
    assert_equal "VALIDATION_FAILED", res.error.code
  end

  test "write tools are rate limited per session" do
    create_ticket
    tools = tools_for(agent_session)
    statuses = (Agentboard::McpTools::WRITE_LIMIT_PER_MINUTE + 1).times.map { tools.call("add_comment", { "ticket_key" => "AB-1", "body" => "hi" }) }
    assert_equal "RATE_LIMITED", statuses.last.error.code
  end

  test "every tool has a strict JSON schema" do
    Agentboard::McpTools::DEFINITIONS.each do |name, (_desc, schema, _write)|
      # permission_prompt's request shape is defined by the provider, so it stays open.
      assert_equal(name != "permission_prompt", schema["additionalProperties"] == false, name)
      assert Agentboard::McpTools.method_defined?("tool_#{name}"), name
    end
  end
end

class McpStdioTest < ActiveSupport::TestCase
  test "stdio handshake, tool discovery and calls; stdout carries only protocol frames" do
    dummy = File.expand_path("../dummy", __dir__)
    env = { "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__) }
    cmd = [ RbConfig.ruby, "-rbundler/setup", File.expand_path("../../exe/agentboard", __dir__), "mcp", "serve", "--root", dummy, "--provider", "claude" ]
    Open3.popen3(env, *cmd, chdir: dummy) do |stdin, stdout, _stderr, wait|
      send = ->(msg) { stdin.puts(JSON.generate(msg)); stdin.flush }
      read = -> { JSON.parse(stdout.gets || raise("no response")) }
      send.(jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } })
      init = read.()
      assert_equal "agentboard", init.dig("result", "serverInfo", "name")
      send.(jsonrpc: "2.0", method: "notifications/initialized")
      send.(jsonrpc: "2.0", id: 2, method: "tools/list")
      names = read.().dig("result", "tools").map { |t| t["name"] }
      %w[list_tickets get_ticket claim_ticket submit_for_review complete_ticket].each { |n| assert_includes names, n }
      send.(jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "list_tickets", arguments: {} })
      body = JSON.parse(read.().dig("result", "content", 0, "text"))
      assert_equal true, body["ok"]
      send.(jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "claim_ticket", arguments: { ticket_key: "bad key" } })
      res = read.()
      assert(res["error"] || res.dig("result", "isError"), "invalid input is rejected at the boundary")
      send.(jsonrpc: "2.0", id: 5, method: "resources/read", params: { uri: "agentboard://session/current" })
      session = JSON.parse(read.().dig("result", "contents", 0, "text"))
      assert_equal "mcp_stdio", session["trust_level"]
      stdin.close
      wait.value
    end
  end
end
