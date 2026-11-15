require "test_helper"

class LicenseTest < ActiveSupport::TestCase
  L = Agentboard::Pro::License

  test "licence states: missing, valid, grace, expired, invalid signature, foreign key" do
    assert_equal "missing", L.current.state
    refute Agentboard.feature?(:git_hosting)
    with_pro(:git_hosting)
    assert_equal "valid", L.current.state
    assert Agentboard.feature?(:git_hosting)
    refute Agentboard.feature?(:team_mode), "only licensed features are enabled"
    legacy = L.issue(private_key_pem: TEST_PRO_PRIVATE_KEY, licensee: "Old", features: %w[github], expires_at: Time.now + 86_400)
    assert_equal [ "git_hosting" ], L.verify(legacy).features, "licences issued with 'github' keep working"

    token = ENV["AGENTBOARD_LICENSE"]
    L.clock = -> { Time.now.utc + 40 * 86_400 }
    assert_equal "grace", L.verify(token).state
    L.clock = -> { Time.now.utc + 60 * 86_400 }
    assert_equal "expired", L.verify(token).state
    assert_empty L.verify(token).enabled_features
    L.clock = nil

    tampered = token.sub(/\A[^.]+/) { |p| Base64.urlsafe_encode64(Base64.urlsafe_decode64(p).sub("Test Co", "Evil Co"), padding: false) }
    assert_equal "invalid", L.verify(tampered).state
    foreign_priv, = L.generate_keypair
    foreign = L.issue(private_key_pem: foreign_priv, licensee: "Pirate", features: L::ALL_FEATURES, expires_at: Time.now + 86_400)
    assert_equal "invalid", L.verify(foreign).state
  ensure
    L.clock = nil
  end
end

class CommunityEditionTest < ActionDispatch::IntegrationTest
  setup { host! "localhost" }

  test "advanced workflows are refused without Pro; sequential workflows stay free" do
    simple = "version: 1\nname: simple\nsteps:\n  - { id: a, type: agent, provider: fake, action: implement }\n  - { id: ok, type: human_approval, depends_on: [a] }\n"
    assert Agentboard::WorkflowEngine.register!(project: @project, yaml: simple)
    advanced = "version: 1\nname: adv\nsteps:\n  - { id: a, type: agent, provider: fake, action: implement, retry: { max_attempts: 2, retry_on: [provider_unavailable] } }\n"
    err = assert_error_code("POLICY_DENIED") { Agentboard::WorkflowEngine.register!(project: @project, yaml: advanced) }
    assert_match(/retries/, err.message)
    post "/agentboard/workflows/validate", params: { yaml: advanced }, as: :json
    assert_includes response.parsed_body["errors"].join, "AgentBoard Pro"
  end

  test "a definition registered under Pro cannot start after the licence lapses" do
    with_pro(:advanced_workflows)
    d = Agentboard::WorkflowEngine.register!(project: @project, yaml: "version: 1\nname: c\nsteps:\n  - { id: a, type: condition, condition: \"ticket.priority <= 3\" }\n")
    without_pro
    assert_error_code("POLICY_DENIED") { Agentboard::WorkflowEngine.start!(definition: d, ticket: create_ticket, actor: human) }
  end

  test "GitHub webhooks do not exist without a github licence" do
    ENV["AGENTBOARD_GITHUB_WEBHOOK_SECRET"] = "s"
    post "/agentboard/webhooks/github", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found
    with_pro(:git_hosting)
    post "/agentboard/webhooks/github", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :unauthorized, "now it exists and demands a signature"
  ensure
    ENV.delete("AGENTBOARD_GITHUB_WEBHOOK_SECRET")
  end

  test "manual PR links and retention stay free" do
    t = create_ticket
    assert Agentboard::PullRequests.link_manually!(ticket: t, actor: human, url: "https://example.com/pr/1", state: "open")
    assert Agentboard::DataGovernance.apply_retention!(project: @project, dry_run: true)
  end

  test "analytics shows Pro metrics only with a governance licence" do
    get "/agentboard/analytics"
    assert_includes response.body, "part of <strong>AgentBoard Pro</strong>"
    with_pro(:governance)
    get "/agentboard/analytics"
    assert_includes response.body, "Queue wait (median / p95)"
  end
end

class TeamModeTest < ActionDispatch::IntegrationTest
  User = Struct.new(:id, :email, :role)

  setup do
    host! "team.example.com"
    @users = { "alice" => User.new(1, "alice@example.com", "maintainer"), "bob" => User.new(2, "bob@example.com", "maintainer"),
               "vic" => User.new(3, "vic@example.com", "viewer") }
    users = @users
    Agentboard.config.authenticate_with = Agentboard::Pro::Team.adapter(
      user: ->(c) { users[c.request.headers["X-Test-User"]] }, role: ->(u) { u.role }, name: ->(u) { u.email }
    )
  end

  teardown { Agentboard.config.authenticate_with = nil }

  def as(user) = { "X-Test-User" => user, "REMOTE_ADDR" => "203.0.113.5" }

  test "without a team_mode licence the host adapter is ignored and access stays local-only" do
    get "/agentboard", headers: as("alice"), env: { "REMOTE_ADDR" => "203.0.113.5" }
    assert_response :forbidden
    get "/agentboard", env: { "REMOTE_ADDR" => "127.0.0.1" }
    assert_response :success
    assert_includes response.body, "needs a Pro licence with team_mode"
  end

  test "with team_mode: users authenticate through the host app and roles are enforced" do
    with_pro(:team_mode)
    get "/agentboard", env: { "REMOTE_ADDR" => "203.0.113.5" }
    assert_response :unauthorized
    get "/agentboard", headers: as("alice"), env: { "REMOTE_ADDR" => "203.0.113.5" }
    assert_response :success
    assert_includes response.body, "alice@example.com"

    t = create_ticket(status: "backlog", criteria: [ "x" ])
    post "/agentboard/tickets/#{t.key}/move", params: { to: "ready" }, headers: as("vic"), env: { "REMOTE_ADDR" => "203.0.113.5" }, as: :json
    assert_response :forbidden
    get "/agentboard/tickets/#{t.key}", headers: as("vic"), env: { "REMOTE_ADDR" => "203.0.113.5" }
    assert_includes response.body, "Read-only"
    post "/agentboard/tickets/#{t.key}/move", params: { to: "ready" }, headers: as("alice"), env: { "REMOTE_ADDR" => "203.0.113.5" }, as: :json
    assert_response :success
    ev = t.events.where(event_type: "ticket.transitioned").last
    assert_equal "user:1", ev.actor_id, "audit trail records the real user"
  end

  test "separation of duties: the requester cannot decide their own approval" do
    with_pro(:team_mode)
    alice = Agentboard::Authorization::Actor.new(type: "human", id: "user:1", role: "maintainer", name: "alice@example.com")
    bob = Agentboard::Authorization::Actor.new(type: "human", id: "user:2", role: "maintainer", name: "bob@example.com")
    a = Agentboard::Approvals.request!(project: @project, actor: alice, action_kind: "privileged_shell", action_payload: { cmd: "x" })
    assert_error_code("FORBIDDEN") { Agentboard::Approvals.decide!(approval: a, actor: alice, decision: "approved") }
    Agentboard::Approvals.decide!(approval: a, actor: bob, decision: "approved")
    assert_equal "approved", a.reload.decision
  end

  test "team mode requires PostgreSQL" do
    with_pro(:team_mode)
    if Agentboard::Pro::Team.sqlite?
      assert_error_code("POLICY_DENIED") { Agentboard::Extensions.run(:runtime_start) }
      assert(Agentboard::Doctor.new(root: @repo_dir).checks.any? { |c| c.name == "Team mode" && c.status == "fail" })
    else
      assert_nothing_raised { Agentboard::Extensions.run(:runtime_start) }
      assert(Agentboard::Doctor.new(root: @repo_dir).checks.any? { |c| c.name == "Team mode" && c.status == "ok" })
    end
  end
end

class GovernanceProTest < ActiveSupport::TestCase
  test "audit export is hash-chained and detects tampering" do
    t = create_ticket
    Agentboard::Tickets.add_comment!(ticket: t, actor: human, body: "hello")
    data = Agentboard::Pro::Governance.audit_export(project: @project)
    assert_operator data["records"].size, :>=, 3
    assert Agentboard::Pro::Governance.verify_audit_export(data)
    data["records"][1]["event"]["payload"]["title"] = "rewritten history"
    refute Agentboard::Pro::Governance.verify_audit_export(data)
  end

  test "scheduled retention runs at most once a day and only with a governance licence" do
    Agentboard::Pro::Governance.scheduled_retention
    assert_nil @project.reload.settings["last_retention_at"]
    with_pro(:governance)
    Agentboard::Pro::Governance.scheduled_retention
    first = @project.reload.settings["last_retention_at"]
    assert first
    Agentboard::Pro::Governance.scheduled_retention(now: Time.current + 3600)
    assert_equal first, @project.reload.settings["last_retention_at"]
    assert_equal 1, Agentboard::Event.where(event_type: "security.retention_applied").count
  end
end
