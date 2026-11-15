require "test_helper"

class BoardFeaturesTest < ActionDispatch::IntegrationTest
  setup { host! "localhost" }

  test "milestones: create, assign on ticket creation, filter and progress" do
    post "/agentboard/milestones", params: { milestone: { name: "Checkout v2", target_date: "2026-12-01" } }
    m = Agentboard::Milestone.find_by!(name: "Checkout v2")
    post "/agentboard/tickets", params: { ticket: { title: "In milestone", criteria: "x", milestone_id: m.id, status: "ready" } }
    create_ticket(title: "Not in milestone")
    get "/agentboard/board", params: { milestone: m.id }
    assert_includes response.body, "In milestone"
    refute_includes response.body, "Not in milestone"
    get "/agentboard/milestones"
    assert_includes response.body, "0/1"
  end

  test "subtasks can be created from a parent ticket" do
    parent = create_ticket
    get "/agentboard/tickets/new", params: { parent: parent.id }
    assert_includes response.body, "Subtask of"
    post "/agentboard/tickets", params: { ticket: { title: "Child", criteria: "x", parent_id: parent.id } }
    assert_equal [ "Child" ], parent.subtasks.pluck(:title)
  end

  test "board columns are configurable and hidden states fold into visible columns" do
    Agentboard.config.settings["board"]["columns"] = %w[backlog ready in_progress review done]
    assert_equal "ready", Agentboard.config.board_column_for("claimed")
    assert_equal "in_progress", Agentboard.config.board_column_for("testing")
    t = create_ticket
    Agentboard::LeaseService.claim!(ticket: t, actor: human)
    get "/agentboard/board"
    assert_response :success
    refute_includes response.body, ">Claimed<"
    assert_includes response.body, t.title
  ensure
    Agentboard.config.settings["board"]["columns"] = Agentboard::Configuration::DEFAULTS["board"]["columns"]
  end
end
