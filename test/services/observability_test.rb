require "test_helper"

class ObservabilityTest < ActiveSupport::TestCase
  test "structured JSON log records carry component and redact secrets" do
    line = Agentboard::JsonLogFormatter.new.call("ERROR", Time.utc(2026, 1, 1), "agentboard", "[agentboard.mcp] tool failed token=ghp_abcdefghijklmnopqrstuvwxyz0123456789")
    rec = JSON.parse(line)
    assert_equal "error", rec["level"]
    assert_equal "mcp", rec["component"]
    refute_includes rec["message"], "ghp_"
  end

  test "metrics come from persisted records; unknown values are nil, not zero" do
    m = Agentboard::Pro::Metrics.snapshot(@project)
    assert_nil m[:queue_wait_median]
    assert_nil m[:approval_latency_median]
    t = create_ticket
    run_execution(Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human))
    FileUtils.mkdir_p(Agentboard.config.workspace_path.join("stray-dir"))
    m = Agentboard::Pro::Metrics.snapshot(@project)
    refute_nil m[:queue_wait_median]
    assert_equal 1, m[:orphan_worktrees]
  end

  test "retention removes provider output events but keeps the audit trail" do
    t = create_ticket
    e = run_execution(Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human))
    assert Agentboard::Event.where(execution_id: e.id, event_type: "agent.execution.message").exists?
    dry = Agentboard::DataGovernance.apply_retention!(project: @project, dry_run: true, now: 60.days.from_now)
    assert_operator dry[:provider_output_events], :>, 0
    assert Agentboard::Event.where(execution_id: e.id, event_type: "agent.execution.message").exists?, "dry run changes nothing"
    Agentboard::DataGovernance.apply_retention!(project: @project, now: 60.days.from_now)
    refute Agentboard::Event.where(execution_id: e.id, event_type: "agent.execution.message").exists?
    assert Agentboard::Event.where(ticket_id: t.id, event_type: "ticket.transitioned").exists?, "audit events are kept"
  end

  test "purge requires an administrator and the exact project key" do
    create_ticket
    assert_error_code("VALIDATION_FAILED") { Agentboard::DataGovernance.purge_project!(project: @project, confirm: "nope", actor: human) }
    dev = Agentboard::Authorization::Actor.new(type: "human", id: "d", role: "developer")
    assert_error_code("FORBIDDEN") { Agentboard::DataGovernance.purge_project!(project: @project, confirm: "AB", actor: dev) }
    counts = Agentboard::DataGovernance.purge_project!(project: @project, confirm: "AB", actor: human)
    assert_equal 1, counts[:tickets]
    refute Agentboard::Project.exists?(@project.id)
  end
end
