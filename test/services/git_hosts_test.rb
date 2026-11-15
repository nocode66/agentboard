require "test_helper"
require "socket"

class GitHostsTest < ActionDispatch::IntegrationTest
  setup do
    with_pro(:git_hosting)
    host! "localhost"
    Agentboard.config.settings["completion"]["require_merged_pr"] = "always"
  end

  teardown do
    %w[AGENTBOARD_GITLAB_WEBHOOK_TOKEN AGENTBOARD_BITBUCKET_WEBHOOK_SECRET GITLAB_TOKEN BITBUCKET_TOKEN].each { |k| ENV.delete(k) }
    Agentboard.config.settings["git_hosts"] = { "default" => nil }
  end

  def reviewed_ticket
    t = create_ticket
    e = run_execution(Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human))
    t.acceptance_criteria.each { |c| Agentboard::Tickets.set_criterion_state!(criterion: c, actor: human, state: "verified") }
    Agentboard::Approvals.decide!(approval: Agentboard::Approval.pending.find_by!(ticket_id: t.id), actor: human, decision: "approved")
    [ t, e ]
  end

  # --- GitLab ----------------------------------------------------------------------------
  def gitlab_payload(e, state:, repo: "acme/shop")
    { "object_kind" => "merge_request", "project" => { "path_with_namespace" => repo },
      "object_attributes" => { "iid" => 7, "title" => "AB-1", "url" => "https://gitlab.com/#{repo}/-/merge_requests/7", "state" => state,
                               "action" => state == "merged" ? "merge" : "open", "source_branch" => e.branch, "target_branch" => "main",
                               "last_commit" => { "id" => e.head_sha }, "merge_commit_sha" => state == "merged" ? "c" * 40 : nil } }.to_json
  end

  def gitlab(body, token: "gl-token", uuid: SecureRandom.uuid)
    post "/agentboard/webhooks/gitlab", params: body, headers: { "CONTENT_TYPE" => "application/json", "X-Gitlab-Event" => "Merge Request Hook",
                                                                 "X-Gitlab-Token" => token, "X-Gitlab-Event-UUID" => uuid }
  end

  test "GitLab merge request hooks: token auth, replay safety and merge-aware completion" do
    ENV["AGENTBOARD_GITLAB_WEBHOOK_TOKEN"] = "gl-token"
    Agentboard.config.settings["git_hosts"] = { "gitlab" => { "repository" => "acme/shop" } }
    t, e = reviewed_ticket
    gitlab(gitlab_payload(e, state: "opened"), token: "wrong")
    assert_response :unauthorized
    gitlab(gitlab_payload(e, state: "opened"), uuid: "u1")
    gitlab(gitlab_payload(e, state: "opened"), uuid: "u1")
    assert_equal 1, Agentboard::WebhookDelivery.where(provider: "gitlab", delivery_id: "u1").count
    assert_equal "open", t.artifacts.find_by!(kind: "pull_request").metadata["state"]
    assert_equal "review", t.reload.status
    gitlab(gitlab_payload(e, state: "merged"))
    assert_equal "done", t.reload.status
    gitlab(gitlab_payload(e, state: "merged", repo: "evil/fork"))
    assert_equal "ignored", Agentboard::WebhookDelivery.order(:created_at).last.status
  end

  # --- Bitbucket -------------------------------------------------------------------------
  def bitbucket_payload(e, state:)
    { "repository" => { "full_name" => "acme/shop" },
      "pullrequest" => { "id" => 3, "title" => "AB-1", "state" => state, "links" => { "html" => { "href" => "https://bitbucket.org/acme/shop/pull-requests/3" } },
                         "source" => { "branch" => { "name" => e.branch }, "commit" => { "hash" => e.head_sha[0, 12] } },
                         "destination" => { "branch" => { "name" => "main" } }, "merge_commit" => state == "MERGED" ? { "hash" => "d" * 12 } : nil } }.to_json
  end

  def bitbucket(body, event:, secret: "bb-secret")
    post "/agentboard/webhooks/bitbucket", params: body,
         headers: { "CONTENT_TYPE" => "application/json", "X-Event-Key" => event, "X-Request-UUID" => SecureRandom.uuid,
                    "X-Hub-Signature" => "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}" }
  end

  test "Bitbucket pull request hooks: HMAC auth, short SHA resolution and completion" do
    ENV["AGENTBOARD_BITBUCKET_WEBHOOK_SECRET"] = "bb-secret"
    Agentboard.config.settings["git_hosts"] = { "bitbucket" => { "repository" => "acme/shop" } }
    t, e = reviewed_ticket
    bitbucket(bitbucket_payload(e, state: "OPEN"), event: "pullrequest:created", secret: "forged")
    assert_response :unauthorized
    bitbucket(bitbucket_payload(e, state: "OPEN"), event: "pullrequest:created")
    pr = t.artifacts.find_by!(kind: "pull_request")
    assert_equal e.head_sha, pr.metadata["head_sha"], "12-char SHA resolved to the full commit"
    bitbucket(bitbucket_payload(e, state: "MERGED"), event: "pullrequest:fulfilled")
    assert_equal "done", t.reload.status
  end

  test "each host's endpoint only exists when its secret is configured" do
    post "/agentboard/webhooks/gitlab", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found
    post "/agentboard/webhooks/bitbucket", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found
  end

  # --- PR creation through the hosts' APIs (stubbed locally) ------------------------------
  def with_api_stub(response)
    server = TCPServer.new("127.0.0.1", 0)
    seen = Queue.new
    thread = Thread.new do
      client = server.accept
      request_line = client.gets
      headers = {}
      while (l = client.gets) && l != "\r\n"
        k, v = l.split(": ", 2)
        headers[k.downcase] = v.to_s.strip
      end
      body = client.read(headers["content-length"].to_i)
      seen << [ request_line, headers, JSON.parse(body) ]
      json = response.to_json
      client.write("HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
      client.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}", seen
  ensure
    thread&.kill
    server&.close
  end

  test "GitLab and Bitbucket open merge/pull requests through their APIs with scoped tokens" do
    ENV["GITLAB_TOKEN"] = "glpat-test"
    ENV["BITBUCKET_TOKEN"] = "bb-test"
    repo = @project.repository
    with_api_stub("web_url" => "https://gitlab.example/acme/shop/-/merge_requests/9") do |base, seen|
      Agentboard.config.settings["git_hosts"] = { "gitlab" => { "base_url" => base, "repository" => "acme/shop", "token_env" => "GITLAB_TOKEN" } }
      url = Agentboard::Pro::GitHosts.fetch("gitlab").create_pull_request(repo: repo, branch: "agentboard/AB-1/exec-001", base: "main", title: "AB-1: x", body: "b")
      assert_equal "https://gitlab.example/acme/shop/-/merge_requests/9", url
      line, headers, body = seen.pop
      assert_includes line, "/api/v4/projects/acme%2Fshop/merge_requests"
      assert_equal "glpat-test", headers["private-token"]
      assert_equal "agentboard/AB-1/exec-001", body["source_branch"]
    end
    with_api_stub("links" => { "html" => { "href" => "https://bitbucket.org/acme/shop/pull-requests/4" } }) do |base, seen|
      Agentboard.config.settings["git_hosts"] = { "bitbucket" => { "api_url" => base, "repository" => "acme/shop", "token_env" => "BITBUCKET_TOKEN" } }
      url = Agentboard::Pro::GitHosts.fetch("bitbucket").create_pull_request(repo: repo, branch: "b", base: "main", title: "t", body: "b")
      assert_equal "https://bitbucket.org/acme/shop/pull-requests/4", url
      line, headers, body = seen.pop
      assert_includes line, "/2.0/repositories/acme/shop/pullrequests"
      assert_equal "Bearer bb-test", headers["authorization"]
      assert_equal "main", body.dig("destination", "branch", "name")
    end
  end

  test "the default host is detected from the origin remote" do
    git!("remote", "add", "origin", "git@bitbucket.org:acme/shop.git")
    assert_equal "bitbucket", Agentboard::Pro::GitHosts.default_for(@project).key
    git!("remote", "set-url", "origin", "https://gitlab.com/acme/shop.git")
    assert_equal "gitlab", Agentboard::Pro::GitHosts.default_for(@project).key
    assert_equal "acme/shop", Agentboard::Pro::GitHosts.fetch("gitlab").repository_identity(@project)
  end
end
