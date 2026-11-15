require "test_helper"

class ExecutionRuntimeTest < ActiveSupport::TestCase
  def enqueue(ticket, scenario: "success", action: "implement")
    Agentboard::Executions.enqueue!(ticket: ticket, provider_key: "fake", actor: human, action: action, metadata: { "scenario" => scenario })
  end

  test "AT-05: active launch creates a unique worktree, snapshots, verifies and hands off for review" do
    t = create_ticket
    e = run_execution(enqueue(t))
    assert_equal "completed", e.status, e.failure_message
    assert File.directory?(e.worktree_path)
    assert_equal "agentboard/AB-1/exec-001", e.branch
    assert e.worktree_path.end_with?(".agentboard/worktrees/AB-1-exec-001")
    refute_equal e.base_sha, e.head_sha
    assert_includes File.read(File.join(e.worktree_path, "AGENTBOARD_NOTES.md")), "AB-1"
    assert_equal [ "passed" ], e.verification_results.map(&:status)
    assert_equal e.head_sha, e.verification_results.first.commit_sha
    assert_equal "review", t.reload.status
    assert Agentboard::Approval.pending.where(ticket_id: t.id, action_kind: "review_completion", head_sha: e.head_sha).exists?
    assert_equal 0, t.leases.live.count
    types = e.events.pluck(:event_type)
    %w[agent.execution.preparing agent.execution.running agent.tool.started agent.execution.result agent.execution.completed].each { |ty| assert_includes types, ty }
    assert e.events.where(event_type: "agent.tool.started").all? { |ev| ev.provenance == "provider_reported" }
    assert e.usage_records.any?
    assert e.artifacts.where(kind: "context").exists?
    assert_equal "clean", (git!("status", "--porcelain").strip.empty? ? "clean" : "dirty"), "main checkout must be untouched"
  end

  test "failed provider leaves the ticket actionable and is never marked complete" do
    t = create_ticket
    e = run_execution(enqueue(t, scenario: "fail"))
    assert_equal "failed", e.status
    assert_equal "provider_failed", e.failure_code
    assert_includes %w[in_progress claimed], t.reload.status
    retry_e = Agentboard::Executions.retry!(execution: e, actor: human)
    assert_equal 2, retry_e.attempt
    assert_equal e.id, retry_e.metadata["retry_of"]
  end

  test "AT-06: cancellation terminates the process group within the grace period" do
    t = create_ticket
    e = enqueue(t, scenario: "slow")
    runner = Thread.new { ActiveRecord::Base.connection_pool.with_connection { Agentboard::Runtime::ExecutionRunner.new(Agentboard::Execution.find(e.id)).call } }
    deadline = Time.now + 10
    sleep 0.1 until e.reload.status == "running" && e.pid || Time.now > deadline
    pid = e.pid
    assert pid
    Agentboard::Executions.request_cancel!(execution: e, actor: human)
    runner.join(10)
    assert_equal "cancelled", e.reload.status, "#{e.failure_code}: #{e.failure_message}"
    refute Agentboard::Subprocess.alive?(pid), "agent process must be gone"
  end

  test "AT-07: restart reconciliation marks running attempts interrupted and never re-runs them" do
    t = create_ticket
    e = enqueue(t)
    sleeper = Process.spawn("sleep", "30", pgroup: true)
    e.update!(status: "running", pid: sleeper, pgid: sleeper, process_fingerprint: Agentboard::Subprocess.fingerprint(sleeper), started_at: Time.current)
    report = Agentboard::Runtime::Reconciler.new.call
    Process.wait(sleeper) rescue nil
    assert_includes report[:interrupted], e.id
    assert_includes report[:orphaned], e.id
    assert_equal "interrupted", e.reload.status
    assert_equal "runtime_restart", e.failure_code
    refute Agentboard::Subprocess.alive?(sleeper)
    assert_equal 1, Agentboard::Execution.where(ticket_id: t.id).count, "no automatic re-run"
  end

  test "reconciler never signals a reused PID whose fingerprint differs" do
    t = create_ticket
    e = enqueue(t)
    other = Process.spawn("sleep", "5", pgroup: true)
    e.update!(status: "running", pid: other, pgid: other, process_fingerprint: "not-the-same", started_at: Time.current)
    Agentboard::Runtime::Reconciler.new.call
    assert Agentboard::Subprocess.alive?(other)
  ensure
    Process.kill("KILL", other) rescue nil
    Process.wait(other) rescue nil
  end

  test "AT-12: concurrent tickets use distinct worktrees" do
    a = create_ticket(title: "a")
    b = create_ticket(title: "b")
    ea = enqueue(a)
    eb = enqueue(b)
    [ ea, eb ].map { |e| Thread.new { ActiveRecord::Base.connection_pool.with_connection { Agentboard::Runtime::ExecutionRunner.new(Agentboard::Execution.find(e.id)).call } } }.each(&:join)
    ea.reload
    eb.reload
    assert_equal %w[completed completed], [ ea.status, eb.status ]
    refute_equal ea.worktree_path, eb.worktree_path
    refute_equal ea.branch, eb.branch
  end

  test "one active execution per ticket" do
    t = create_ticket
    enqueue(t)
    assert_error_code("WORKSPACE_CONFLICT") { enqueue(t) }
  end

  test "AT-13: secrets in provider output are redacted in logs and events and audited" do
    t = create_ticket
    e = run_execution(enqueue(t, scenario: "secret"))
    log = File.read(e.log_path)
    refute_includes log, "sk-ant-api03"
    assert_includes log, "[REDACTED]"
    refute(Agentboard::Event.where(execution_id: e.id).any? { |ev| ev.payload.to_json.include?("sk-ant-api03") })
    assert Agentboard::Event.where(execution_id: e.id, event_type: "security.secret_redacted").exists?
  end

  test "malformed provider output is tolerated and labeled" do
    t = create_ticket
    e = run_execution(enqueue(t, scenario: "malformed"))
    assert_equal "completed", e.status
    assert e.events.where(event_type: "agent.execution.output").exists?
    assert e.events.where(event_type: "agent.provider.unknown").exists?
  end

  test "real providers require explicit trusted local execution" do
    t = create_ticket
    probe = Agentboard::Providers::ProbeResult.new(provider: :claude, installed: true, version: "2.1.325", supported_capabilities: [ :active_execution ], diagnostics: [])
    Agentboard::Providers::ClaudeCode.stub_any_instance(:probe, probe) do
      assert_error_code("POLICY_DENIED") { Agentboard::Executions.enqueue!(ticket: t, provider_key: "claude", actor: human) }
    end
  end

  test "AT-14: unknown provider versions get conservative capabilities" do
    klass = Agentboard::Providers::ClaudeCode
    adapter = klass.new(settings: {})
    caps, validation, diags = adapter.send(:negotiate, "9.9.9", %i[mcp passive_hooks active_execution], safe_caps: %i[mcp passive_hooks])
    assert_equal %i[mcp passive_hooks], caps
    assert_equal "unknown version", validation
    assert_match(/disabled/, diags.first)
  end

  test "supervisor claims queued work fairly and respects the concurrency limit" do
    t1 = create_ticket(title: "low", priority: 3)
    t2 = create_ticket(title: "urgent", priority: 0)
    e1 = enqueue(t1)
    e2 = enqueue(t2)
    sup = Agentboard::Runtime::Supervisor.new
    sup.start_queued
    started = sup.workers.keys
    assert_equal [ e2.id ], started, "urgent ticket first, one at a time"
    sup.workers.each_value { |th| th.join(30) }
    sup.start_queued
    sup.workers.each_value { |th| th.join(30) }
    assert_equal "completed", e1.reload.status
  end
end

# Minimal any-instance stub helper (Minitest 6 dropped minitest/mock from core).
class Class
  def stub_any_instance(name, value)
    original = instance_method(name)
    define_method(name) { |*_a, **_k| value }
    yield
  ensure
    define_method(name, original)
  end
end

class ResumeAndResourcesTest < ActiveSupport::TestCase
  test "resume continues the provider session as a new attempt in the same worktree" do
    t = create_ticket
    first = run_execution(Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human, metadata: { "scenario" => "fail" }))
    assert_equal "failed", first.status
    sid = first.metadata["provider_session_id"]
    assert sid
    resumed = run_execution(Agentboard::Executions.resume!(execution: first, actor: human, message: "Please try again"))
    assert_equal 2, resumed.attempt
    assert_equal first.worktree_path, resumed.worktree_path, "same worktree"
    assert_equal sid, resumed.metadata["provider_session_id"], "same provider session"
    assert(resumed.events.where(event_type: "agent.execution.message").any? { |ev| ev.data["text"].include?("Resumed session #{sid}: Please try again") })
    assert_equal "completed", resumed.status
  end

  test "resume is refused when the provider has no session or the attempt is active" do
    t = create_ticket
    e = Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human)
    assert_error_code("INVALID_TRANSITION") { Agentboard::Executions.resume!(execution: e, actor: human) }
  end

  test "process-group resource usage is sampled and recorded" do
    t = create_ticket
    e = run_execution(Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human, metadata: { "scenario" => "slow" }))
    res = e.metadata["resources"]
    assert res, "resources recorded"
    assert_operator res["peak_rss_kb"], :>, 0
    assert_operator res["cpu_seconds"], :>=, 0
    assert_in_delta 3723.5, Agentboard::Subprocess.parse_cpu_time("01:02:03.5"), 0.01
    assert_in_delta 90_062, Agentboard::Subprocess.parse_cpu_time("1-01:01:02"), 0.01
  end
end
