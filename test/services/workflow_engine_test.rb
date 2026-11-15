require "test_helper"

class WorkflowEngineTest < ActiveSupport::TestCase
  YAML_DEF = <<~Y
    version: 1
    name: delivery
    steps:
      - { id: plan, type: agent, provider: fake, action: plan }
      - { id: implement, type: agent, provider: fake, action: implement, depends_on: [plan] }
      - { id: test, type: command, command: rails_test, depends_on: [implement] }
      - { id: review, type: agent, provider: fake, action: review, depends_on: [test] }
      - { id: approval, type: human_approval, depends_on: [review] }
      - { id: fix, type: agent, provider: fake, action: fix_tests, depends_on: [test], condition: "steps.test.status == 'failed'" }
  Y

  setup { with_pro(:advanced_workflows) }

  def drive(run, until_status:, timeout: 60)
    deadline = Time.now + timeout
    loop do
      Agentboard::WorkflowEngine.advance(run.reload)
      Agentboard::Execution.where(status: "queued").find_each { |e| Agentboard::Runtime::ExecutionRunner.new(e).call }
      return run.reload if Array(until_status).include?(run.reload.status) || Time.now > deadline

      sleep 0.1
    end
  end

  test "AT-09: plan -> implement -> test -> review -> approval with verified handoffs" do
    t = create_ticket
    definition = Agentboard::WorkflowEngine.register!(project: @project, yaml: YAML_DEF)
    assert_equal definition, Agentboard::WorkflowEngine.register!(project: @project, yaml: YAML_DEF), "same digest reuses the version"
    run = Agentboard::WorkflowEngine.start!(definition: definition, ticket: t, actor: human)
    run = drive(run, until_status: "waiting_for_approval")
    steps = run.current_steps
    assert_equal %w[succeeded succeeded succeeded succeeded waiting skipped], %w[plan implement test review approval fix].map { |k| steps[k].status }
    impl_head = steps["implement"].output["head_sha"]
    assert impl_head
    assert @project.repository.resolve_commit(impl_head), "handoff head must exist in the repository"
    review_exec = steps["review"].executions.first
    assert_equal impl_head, review_exec.base_sha, "review starts from the implementation commit"

    approval = Agentboard::Approval.find(steps["approval"].output["approval_id"])
    Agentboard::Approvals.decide!(approval: approval, actor: human, decision: "approved")
    run = drive(run, until_status: %w[succeeded failed])
    assert_equal "succeeded", run.status
  end

  test "rejected approval fails the run; cancellation propagates" do
    t = create_ticket
    yaml = "version: 1\nname: gate\nsteps:\n  - { id: approve, type: human_approval }\n  - { id: after, type: agent, provider: fake, action: plan, depends_on: [approve] }\n"
    run = Agentboard::WorkflowEngine.start!(definition: Agentboard::WorkflowEngine.register!(project: @project, yaml: yaml), ticket: t, actor: human)
    Agentboard::WorkflowEngine.advance(run)
    approval = Agentboard::Approval.find(run.reload.current_steps["approve"].output["approval_id"])
    Agentboard::Approvals.decide!(approval: approval, actor: human, decision: "rejected")
    run = drive(run, until_status: %w[failed succeeded])
    assert_equal "failed", run.status
    assert_equal "skipped", run.current_steps["after"].status
  end

  test "workflow definitions are immutable once used" do
    t = create_ticket
    d = Agentboard::WorkflowEngine.register!(project: @project, yaml: YAML_DEF)
    Agentboard::WorkflowEngine.start!(definition: d, ticket: t, actor: human)
    assert_raises(Agentboard::Error) { d.update!(definition: d.definition.merge("name" => "other"), digest: "x") }
    v2 = Agentboard::WorkflowEngine.register!(project: @project, yaml: YAML_DEF.sub("action: review", "action: summarize"))
    assert_equal 2, v2.version
  end
end
