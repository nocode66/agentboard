require "test_helper"

class PermissionBridgeTest < ActiveSupport::TestCase
  def running_execution
    t = create_ticket
    e = Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human)
    Agentboard::Executions.transition!(e, "preparing")
    Agentboard::Executions.transition!(e, "running")
    e.reload
  end

  def tools_for(e) = Agentboard::McpTools.new(project: @project, session: e.agent_session, execution: e)

  def decide_when_requested(decision)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        approval = nil
        50.times { break if (approval = Agentboard::Approval.pending.first); sleep 0.1 }
        Agentboard::Approvals.decide!(approval: approval, actor: human, decision: decision, reason: "tested") if approval
      end
    end
  end

  test "approved permission: execution waits for the human, then continues with allow" do
    e = running_execution
    states = []
    watcher = Thread.new { ActiveRecord::Base.connection_pool.with_connection { 30.times { states << Agentboard::Execution.find(e.id).status; sleep 0.05 } } }
    decider = decide_when_requested("approved")
    result = tools_for(e).call("permission_prompt", { "tool_name" => "Bash", "input" => { "command" => "bin/rails test" }, "tool_use_id" => "tu_1" })
    [ decider, watcher ].each(&:join)
    assert result.ok?, result.to_h.inspect
    assert_equal "allow", result.data[:behavior]
    assert_equal({ "command" => "bin/rails test" }, result.data[:updatedInput])
    assert_includes states, "waiting_for_permission"
    assert_equal "running", e.reload.status
    assert_equal "privileged_shell", Agentboard::Approval.last.action_kind
  end

  test "rejected permission returns deny with the reviewer's reason" do
    e = running_execution
    decider = decide_when_requested("rejected")
    result = tools_for(e).call("permission_prompt", { "tool_name" => "Bash", "input" => { command: "curl example.com" } })
    decider.join
    assert_equal "Bash curl example.com", Agentboard::Approval.last.action_payload["summary"], "symbol keys from MCP are normalized"
    assert_equal "deny", result.data[:behavior]
    assert_equal "tested", result.data[:message]
    assert_equal "running", e.reload.status
  end

  test "production deploys, protected pushes and credential reads are denied without asking" do
    e = running_execution
    [ "kamal deploy -d production", "git push --force origin main", "cat config/credentials/production.key", "printenv" ].each do |cmd|
      r = tools_for(e).call("permission_prompt", { "tool_name" => "Bash", "input" => { "command" => cmd } })
      assert_equal "deny", r.data[:behavior], cmd
    end
    assert_equal 0, Agentboard::Approval.count, "no human prompt for forbidden operations"
    assert_equal 4, Agentboard::Event.where(event_type: "security.permission_denied_by_policy").count
  end

  test "execution-bound sessions only see read tools and the permission bridge" do
    e = running_execution
    tools = tools_for(e)
    assert_equal Agentboard::McpTools::EXECUTION_TOOLS.sort, tools.tool_names.sort
    assert_equal "FORBIDDEN", tools.call("claim_ticket", { "ticket_key" => "AB-1", "expected_version" => 0 }).error.code
    s2 = agent_session
    regular = Agentboard::McpTools.new(project: @project, session: s2, credential: Agentboard::SessionCredential.issue!(s2))
    assert_equal "FORBIDDEN", regular.call("permission_prompt", { "tool_name" => "Bash" }).error.code
  end

  test "claude launches with the permission bridge and never with bypass flags" do
    e = running_execution
    spec = Agentboard::Providers::ClaudeCode.new(settings: {}).launch_spec(execution: e, worktree: "/tmp/wt", context_path: "/tmp/c", prompt: "x")
    idx = spec.argv.index("--permission-prompt-tool")
    assert_equal "mcp__agentboard__permission_prompt", spec.argv[idx + 1]
    assert_includes spec.argv, "--strict-mcp-config"
    config = JSON.parse(spec.argv[spec.argv.index("--mcp-config") + 1])
    assert_includes config.dig("mcpServers", "agentboard", "args"), e.id
    refute_includes spec.argv, "--dangerously-skip-permissions"
  end
end
