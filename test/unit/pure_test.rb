require "test_helper"

class StateMachineTest < ActiveSupport::TestCase
  SM = Agentboard::StateMachines

  test "ticket transitions follow the specified table" do
    assert SM::Ticket.allowed?("backlog", "ready")
    assert SM::Ticket.allowed?("review", "done")
    refute SM::Ticket.allowed?("backlog", "done")
    refute SM::Ticket.allowed?("ready", "review")
    refute SM::Ticket.allowed?("cancelled", "ready")
    err = assert_raises(Agentboard::Error) { SM::Ticket.assert!("backlog", "done") }
    assert_equal "INVALID_TRANSITION", err.code
  end

  test "execution states: interrupted is terminal for the attempt" do
    assert SM::Execution.terminal?("interrupted")
    refute SM::Execution.allowed?("interrupted", "running")
    assert SM::Execution.allowed?("running", "waiting_for_permission")
    assert SM::Execution.allowed?("waiting_for_permission", "running")
  end
end

class RedactorTest < ActiveSupport::TestCase
  test "redacts common token formats and sensitive keys (AT-13)" do
    text = "key sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 gh ghp_abcdefghijklmnopqrstuvwxyz0123456789 AKIAABCDEFGHIJKLMNOP password=hunter2secret"
    out, count = Agentboard::Redactor.redact_with_count(text)
    refute_includes out, "sk-ant-api03"
    refute_includes out, "ghp_abcdef"
    refute_includes out, "AKIAABCDEF"
    refute_includes out, "hunter2secret"
    assert_operator count, :>=, 4
    deep = Agentboard::Redactor.redact_value({ "api_key" => "plain", "nested" => { "msg" => "use sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ" } })
    assert_equal "[REDACTED]", deep["api_key"]
    refute_includes deep.dig("nested", "msg"), "sk-proj-ABC"
  end

  test "leaves ordinary text untouched" do
    assert_equal "Fix the invoice total rounding", Agentboard::Redactor.redact("Fix the invoice total rounding")
  end
end

class ConditionTest < ActiveSupport::TestCase
  C = Agentboard::Workflows::Condition

  test "evaluates the restricted grammar" do
    ctx = { "steps" => { "test" => { "status" => "failed", "output" => { "score" => 7 } } }, "ticket" => { "priority" => 1 } }
    assert C.parse("steps.test.status == 'failed'").evaluate(ctx)
    assert C.parse("not steps.test.status == 'succeeded' and ticket.priority <= 1").evaluate(ctx)
    assert C.parse("steps.test.output.score > 5 or false").evaluate(ctx)
    refute C.parse("(steps.test.status == \"succeeded\")").evaluate(ctx)
  end

  test "rejects anything outside the grammar (no eval)" do
    [ "system('rm -rf /')", "steps.test.status == `id`", "ENV.fetch('X') == 1", "steps.test.status ==", "1 == 1" ].each do |src|
      assert_raises(C::SyntaxError, src) { C.parse(src) }
    end
  end
end

class WorkflowDefinitionTest < ActiveSupport::TestCase
  def parse(yaml) = Agentboard::Workflows::Definition.parse_yaml(yaml)

  test "valid DAG yields topological order and stable digest" do
    yaml = <<~Y
      version: 1
      name: feature
      steps:
        - { id: plan, type: agent, provider: fake, action: plan }
        - { id: implement, type: agent, provider: fake, action: implement, depends_on: [plan] }
        - { id: test, type: command, command: rails_test, depends_on: [implement] }
        - { id: gate, type: human_approval, depends_on: [test] }
    Y
    d = parse(yaml)
    assert_equal %w[plan implement test gate], d.topological_order
    assert_equal d.digest, parse(yaml).digest
  end

  test "rejects cycles, unknown deps, shell strings, unsafe YAML and unbounded retries" do
    cyc = "version: 1\nname: x\nsteps:\n  - { id: a, type: condition, depends_on: [b] }\n  - { id: b, type: condition, depends_on: [a] }\n"
    assert_match(/cycle/, assert_raises(Agentboard::Error) { parse(cyc) }.message)
    assert_match(/unknown step/, assert_raises(Agentboard::Error) { parse("version: 1\nname: x\nsteps:\n  - { id: a, type: condition, depends_on: [zz] }\n") }.message)
    assert_match(/catalog/, assert_raises(Agentboard::Error) { parse("version: 1\nname: x\nsteps:\n  - { id: a, type: command, command: 'rm -rf /' }\n") }.message)
    assert_raises(Agentboard::Error) { parse("version: 1\nname: x\nsteps:\n  - &a { id: a, type: condition }\n  - *a\n") }
    assert_match(/max_attempts/, assert_raises(Agentboard::Error) { parse("version: 1\nname: x\nsteps:\n  - { id: a, type: agent, provider: fake, action: plan, retry: { max_attempts: 50 } }\n") }.message)
    assert_raises(Agentboard::Error) { parse("--- !ruby/object:OpenStruct\nfoo: 1\n") }
  end
end

class PathGuardTest < ActiveSupport::TestCase
  test "rejects traversal and symlink escape" do
    root = File.realpath(Dir.mktmpdir)
    FileUtils.mkdir_p(File.join(root, "ws"))
    File.symlink("/etc", File.join(root, "ws", "evil"))
    assert_equal File.join(root, "ws", "a.txt"), Agentboard::PathGuard.within!(File.join(root, "ws"), "a.txt")
    assert_raises(Agentboard::Error) { Agentboard::PathGuard.within!(File.join(root, "ws"), "../outside") }
    assert_raises(Agentboard::Error) { Agentboard::PathGuard.within!(File.join(root, "ws"), "evil/passwd") }
    refute Agentboard::PathGuard.safe_relative?("../x")
    refute Agentboard::PathGuard.safe_relative?("/etc/passwd")
  ensure
    FileUtils.rm_rf(root)
  end
end

class ConfigurationTest < ActiveSupport::TestCase
  test "runtime dir fits the macOS 104-byte socket path limit" do
    path = Agentboard::Runtime::IPC.paths[:socket].to_s
    assert_operator path.bytesize, :<, 104
  end
end
