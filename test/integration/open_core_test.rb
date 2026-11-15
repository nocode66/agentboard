require "test_helper"

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

  test "git hosting webhooks do not exist in the Community edition" do
    post "/agentboard/webhooks/github", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :not_found
  end

  test "manual PR links and retention stay free" do
    t = create_ticket
    assert Agentboard::PullRequests.link_manually!(ticket: t, actor: human, url: "https://example.com/pr/1", state: "open")
    assert Agentboard::DataGovernance.apply_retention!(project: @project, dry_run: true)
  end

  test "analytics points to Pro for operational metrics" do
    get "/agentboard/analytics"
    assert_includes response.body, "part of <strong>AgentBoard Pro</strong>"
  end

  test "extensions unlock features through the public registry" do
    refute Agentboard.feature?(:capture)
    with_features(:capture)
    assert Agentboard.feature?(:capture)
    assert_raises(KeyError) { Agentboard.require_feature!(:unknown_feature) }
  end
end
