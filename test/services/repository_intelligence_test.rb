require "test_helper"

class RepositoryIntelligenceTest < ActiveSupport::TestCase
  test "routes and tables are read statically with Prism (no code execution)" do
    FileUtils.mkdir_p(File.join(@repo_dir, "config"))
    File.write(File.join(@repo_dir, "config/routes.rb"), <<~RUBY)
      Rails.application.routes.draw do
        File.write("/tmp/agentboard-should-not-exist", "pwned")
        root "invoices#index"
        resources :invoices do
          resources :line_items
        end
        get "reports/monthly", to: "reports#monthly"
      end
    RUBY
    FileUtils.mkdir_p(File.join(@repo_dir, "db/migrate"))
    File.write(File.join(@repo_dir, "db/migrate/1_create_invoices.rb"), "create_table :invoices do |t|\nend\n")
    routes = Agentboard::RailsIntrospection.routes(@repo_dir)
    assert_includes routes, { verb: "resources", path: "invoices", kind: "resource" }
    assert_includes routes, { verb: "resources", path: "line_items", kind: "resource" }
    assert_includes routes, { verb: "GET", path: "reports/monthly", kind: "route" }
    assert_includes routes, { verb: "GET", path: "/", kind: "root" }
    refute File.exist?("/tmp/agentboard-should-not-exist"), "routes.rb must never be evaluated"
    assert_equal [ "invoices" ], Agentboard::RailsIntrospection.migration_tables(@repo_dir)
  end

  test "advisor suggests files, size, criteria, subtasks and dependencies; nothing changes until accepted" do
    other = create_ticket(title: "Invoice total currency formatting")
    t = create_ticket(title: "Invoice total rounding", description: "Fix rounding.\n- Round half up in Invoice#total\n- Add regression test for totals\n", kind: "bug")
    before = [ t.acceptance_criteria.count, t.subtasks.count, t.dependencies.count ]
    s = Agentboard::TicketAdvisor.suggest(t)
    kinds = s.map(&:kind)
    assert_includes s.select { |x| x.kind == "file" }.map(&:value), "app/models/invoice.rb"
    assert_includes kinds, "complexity"
    assert_includes s.select { |x| x.kind == "criterion" }.map(&:value), "A regression test reproduces the bug and passes with the fix"
    assert_equal [ "Round half up in Invoice#total", "Add regression test for totals" ], s.select { |x| x.kind == "subtask" }.map(&:value)
    assert_includes s.select { |x| x.kind == "dependency" }.map(&:value), other.key
    assert_equal before, [ t.acceptance_criteria.count, t.subtasks.count, t.dependencies.count ]
  end

  test "executions record a repository snapshot for their base commit" do
    t = create_ticket
    e = run_execution(Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human))
    snap = Agentboard::RepositorySnapshot.find_by!(project_id: @project.id, commit_sha: e.base_sha)
    assert_operator snap.metadata["files"], :>=, 2
    assert_equal 1, snap.metadata["models"]
  end
end
class DashboardSuggestionsTest < ActionDispatch::IntegrationTest
  setup { host! "localhost" }

  test "suggestions render lazily and can be accepted" do
    t = create_ticket(description: "- First step to do\n", kind: "feature")
    get "/agentboard/tickets/#{t.key}/suggestions"
    assert_response :success
    assert_includes response.body, "First step to do"
    post "/agentboard/tickets/#{t.key}/accept_suggestion", params: { kind: "subtask", value: "First step to do" }
    assert_equal [ "First step to do" ], t.subtasks.pluck(:title)
    post "/agentboard/tickets/#{t.key}/accept_suggestion", params: { kind: "complexity", value: "M" }
    assert_includes t.reload.labels, "size:M"
  end
end
