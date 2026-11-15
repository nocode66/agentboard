require "test_helper"

class GithubIntegrationTest < ActionDispatch::IntegrationTest
  SECRET = "whsec-test-123456"

  setup do
    with_pro(:git_hosting)
    host! "localhost"
    ENV["AGENTBOARD_GITHUB_WEBHOOK_SECRET"] = SECRET
    Agentboard.config.settings["github"] = { "webhook_secret_env" => "AGENTBOARD_GITHUB_WEBHOOK_SECRET", "repository" => "acme/shop" }
    Agentboard.config.settings["completion"]["require_merged_pr"] = "always"
  end

  teardown { ENV.delete("AGENTBOARD_GITHUB_WEBHOOK_SECRET") }

  # A ticket in review whose head passed checks and was approved.
  def reviewed_ticket
    t = create_ticket
    e = run_execution(Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human))
    assert_equal "review", t.reload.status
    t.acceptance_criteria.each { |c| Agentboard::Tickets.set_criterion_state!(criterion: c, actor: human, state: "verified") }
    approval = Agentboard::Approval.pending.find_by!(ticket_id: t.id, action_kind: "review_completion")
    Agentboard::Approvals.decide!(approval: approval, actor: human, decision: "approved")
    [ t, e ]
  end

  def pr_payload(e, merged:, repo: "acme/shop", sha: nil)
    {
      "action" => merged ? "closed" : "opened",
      "repository" => { "full_name" => repo },
      "pull_request" => {
        "number" => 42, "title" => "AB-1 totals", "html_url" => "https://github.com/#{repo}/pull/42", "state" => merged ? "closed" : "open",
        "merged" => merged, "merge_commit_sha" => merged ? "f" * 40 : nil, "merged_at" => merged ? Time.now.utc.iso8601 : nil,
        "head" => { "ref" => e.branch, "sha" => sha || e.head_sha }, "base" => { "ref" => "main" }
      }
    }.to_json
  end

  def deliver(body, event: "pull_request", delivery: SecureRandom.uuid, signature: nil)
    post "/agentboard/webhooks/github", params: body,
         headers: { "CONTENT_TYPE" => "application/json", "X-GitHub-Event" => event, "X-GitHub-Delivery" => delivery,
                    "X-Hub-Signature-256" => signature || "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", SECRET, body)}" },
         env: { "REMOTE_ADDR" => "140.82.112.1" }
  end

  test "AT-11: a signed merge webhook for the reviewed head completes the ticket" do
    t, e = reviewed_ticket
    refute Agentboard::CompletionPolicy.evaluate(t)[:ok], "merged PR still missing"
    deliver(pr_payload(e, merged: false))
    assert_response :success
    assert_equal "review", t.reload.status
    deliver(pr_payload(e, merged: true))
    assert_response :success
    assert_equal "done", t.reload.status
    pr = t.artifacts.find_by!(kind: "pull_request")
    assert_equal "merged", pr.metadata["state"]
    assert_equal "branch", pr.metadata["match"]
  end

  test "forged signatures are rejected and audited; nothing changes" do
    t, e = reviewed_ticket
    deliver(pr_payload(e, merged: true), signature: "sha256=" + "0" * 64)
    assert_response :unauthorized
    assert_equal "review", t.reload.status
    assert Agentboard::WebhookDelivery.where(signature_valid: false, status: "rejected").exists?
    assert Agentboard::Event.where(event_type: "security.webhook_rejected").exists?
  end

  test "replayed deliveries are idempotent" do
    t, e = reviewed_ticket
    body = pr_payload(e, merged: false)
    2.times { deliver(body, delivery: "same-id") }
    assert_equal 1, Agentboard::WebhookDelivery.where(delivery_id: "same-id").count
    assert_equal 1, t.artifacts.where(kind: "pull_request").count
    assert_equal 1, t.events.where(event_type: "git.pull_request_open").count
  end

  test "a merge of a different (untested) head does not complete the ticket" do
    t, e = reviewed_ticket
    other = commit_file!("x.rb", "new")
    Agentboard::Artifact.create!(ticket: t, kind: "commit", uri: "git:#{other}", commit_sha: "a" * 40, provenance: "confirmed", metadata: {})
    deliver(pr_payload(e, merged: true, sha: "b" * 40).sub(e.branch, "unrelated-branch"))
    assert_equal "review", t.reload.status
  end

  test "events from other repositories are ignored" do
    t, e = reviewed_ticket
    deliver(pr_payload(e, merged: true, repo: "evil/fork"))
    assert_response :success
    assert_equal "ignored", Agentboard::WebhookDelivery.last.status
    assert_equal "review", t.reload.status
  end

  test "endpoint is disabled without a configured secret" do
    ENV.delete("AGENTBOARD_GITHUB_WEBHOOK_SECRET")
    post "/agentboard/webhooks/github", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found
  end

  test "manual merge links are verified against local Git history" do
    t, e = reviewed_ticket
    assert_error_code("VALIDATION_FAILED") do
      Agentboard::PullRequests.link_manually!(ticket: t, actor: human, url: "https://example.com/pr/1", state: "merged", merge_commit_sha: "c" * 40)
    end
    git!("merge", "--no-ff", "-q", "-m", "merge", e.branch)
    merge_sha = git!("rev-parse", "HEAD").strip
    Agentboard::PullRequests.link_manually!(ticket: t, actor: human, url: "https://example.com/pr/1", state: "merged", merge_commit_sha: merge_sha)
    assert_equal "done", t.reload.status
  end
end
