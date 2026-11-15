require "test_helper"

class DonePolicyTest < ActiveSupport::TestCase
  def reviewed_ticket
    t = create_ticket
    run_execution(Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human))
    t.acceptance_criteria.each { |c| Agentboard::Tickets.set_criterion_state!(criterion: c, actor: human, state: "verified") }
    Agentboard::Approvals.decide!(approval: Agentboard::Approval.pending.find_by!(ticket_id: t.id), actor: human, decision: "approved")
    t
  end

  def link_pr(t, state)
    Agentboard::Artifact.create!(ticket: t, kind: "pull_request", uri: "https://github.com/a/b/pull/#{rand(1000)}", provenance: "confirmed",
                                 metadata: { "state" => state, "head_sha" => Agentboard::Evidence.head_sha(t), "merge_verified" => state == "merged" })
  end

  test "when_linked (default): tickets without a PR complete on other evidence" do
    assert_equal "when_linked", Agentboard::CompletionPolicy.merged_pr_mode
    t = reviewed_ticket
    assert Agentboard::CompletionPolicy.evaluate(t)[:ok]
  end

  test "when_linked: an open PR must be merged first; an abandoned PR does not block" do
    t = reviewed_ticket
    link_pr(t, "closed")
    assert Agentboard::CompletionPolicy.evaluate(t)[:ok], "closed-unmerged PRs are ignored"
    open_pr = link_pr(t, "open")
    refute Agentboard::CompletionPolicy.evaluate(t)[:ok]
    open_pr.update!(metadata: open_pr.metadata.merge("state" => "merged", "merge_verified" => true))
    assert Agentboard::CompletionPolicy.evaluate(t)[:ok]
  end

  test "always / never modes" do
    t = reviewed_ticket
    Agentboard.config.settings["completion"]["require_merged_pr"] = "always"
    refute Agentboard::CompletionPolicy.evaluate(t)[:ok]
    Agentboard.config.settings["completion"]["require_merged_pr"] = "never"
    link_pr(t, "open")
    assert Agentboard::CompletionPolicy.evaluate(t)[:ok]
  end
end
