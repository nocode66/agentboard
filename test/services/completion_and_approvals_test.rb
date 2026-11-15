require "test_helper"

class CompletionAndApprovalsTest < ActiveSupport::TestCase
  def move_to_review(t, sha)
    Agentboard::LeaseService.claim!(ticket: t, actor: human)
    Agentboard::Tickets.transition!(ticket: t, to: "in_progress", actor: human)
    Agentboard::Evidence.attach_commit!(ticket: t, commit_sha: sha, actor: human)
    Agentboard::Tickets.transition!(ticket: t, to: "testing", actor: human)
    Agentboard::VerificationService.verify_repository!(ticket: t, actor: human)
    Agentboard::Tickets.transition!(ticket: t, to: "review", actor: human)
  end

  test "AT-08: checks that passed for SHA A do not authorize SHA B" do
    t = create_ticket
    sha_a = commit_file!("a.rb", "A")
    move_to_review(t, sha_a)
    assert Agentboard::CompletionPolicy.checks_report(t, head_sha: sha_a)[:ok]

    sha_b = commit_file!("b.rb", "B")
    Agentboard::Evidence.attach_commit!(ticket: t, commit_sha: sha_b, actor: human)
    report = Agentboard::CompletionPolicy.checks_report(t.reload, head_sha: sha_b)
    refute report[:ok]
    assert_equal "stale", report[:checks].first[:status]
  end

  test "dirty working tree results are never bound to a commit" do
    t = create_ticket
    sha = git!("rev-parse", "HEAD").strip
    File.write(File.join(@repo_dir, "dirty.rb"), "x")
    results = Agentboard::VerificationService.verify_repository!(ticket: t, actor: human)
    assert results.first.commit_sha.start_with?("unbound:")
    refute Agentboard::CompletionPolicy.checks_report(t, head_sha: sha)[:ok]
  end

  test "done requires verified criteria, passing checks and a human approval bound to head" do
    t = create_ticket
    sha = commit_file!("feature.rb", "ok")
    move_to_review(t, sha)
    report = Agentboard::CompletionPolicy.evaluate(t)
    refute report[:ok]
    assert(report[:missing].any? { |m| m.include?("acceptance criteria") })
    assert(report[:missing].any? { |m| m.include?("approval") })
    assert_error_code("POLICY_DENIED") { Agentboard::CompletionPolicy.complete!(ticket: t, actor: human) }

    t.acceptance_criteria.each { |c| Agentboard::Tickets.set_criterion_state!(criterion: c, actor: human, state: "verified") }
    approval = Agentboard::Approvals.request_review!(ticket: t, actor: system_actor, head_sha: sha)
    Agentboard::Approvals.decide!(approval: approval, actor: human, decision: "approved")
    Agentboard::CompletionPolicy.complete!(ticket: t, actor: human)
    assert_equal "done", t.reload.status
    assert_equal 0, t.leases.live.count
  end

  test "agents cannot verify criteria or decide approvals" do
    t = create_ticket
    s = agent_session
    assert_error_code("FORBIDDEN") { Agentboard::Tickets.set_criterion_state!(criterion: t.acceptance_criteria.first, actor: s.actor, state: "verified") }
    approval = Agentboard::Approvals.request!(project: @project, ticket: t, actor: s.actor, action_kind: "privileged_shell", action_payload: { cmd: "x" })
    assert_error_code("FORBIDDEN") { Agentboard::Approvals.decide!(approval: approval, actor: s.actor, decision: "approved") }
  end

  test "AT-10 / approval replay: code change after approval invalidates it" do
    t = create_ticket
    sha = commit_file!("x.rb", "1")
    approval = Agentboard::Approvals.request!(project: @project, ticket: t, actor: system_actor, action_kind: "protected_branch_merge", head_sha: sha)
    Agentboard::Approvals.decide!(approval: approval, actor: human, decision: "approved")
    assert approval.reload.valid_for?(action_digest: approval.action_digest, head_sha: sha)
    sha2 = commit_file!("x.rb", "2")
    Agentboard::Approvals.invalidate_stale!(ticket: t, head_sha: sha2)
    assert_equal "invalidated", approval.reload.decision
    refute approval.valid_for?(action_digest: approval.action_digest, head_sha: sha2)
  end

  test "expired approvals cannot be granted" do
    approval = Agentboard::Approvals.request!(project: @project, actor: system_actor, action_kind: "production_deploy", ttl: 1.second)
    approval.update!(expires_at: 1.minute.ago)
    assert_error_code("APPROVAL_REQUIRED") { Agentboard::Approvals.decide!(approval: approval, actor: human, decision: "approved") }
  end

  test "attach_commit marks SHAs missing from the repository as unverified" do
    t = create_ticket
    a = Agentboard::Evidence.attach_commit!(ticket: t, commit_sha: "deadbeefdeadbeef", actor: agent_session.actor)
    assert_equal false, a.metadata["verified_in_repo"]
    assert_nil Agentboard::Evidence.head_sha(t)
  end
end
