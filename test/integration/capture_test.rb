require "test_helper"

class CaptureTest < ActionDispatch::IntegrationTest
  setup do
    host! "localhost"
    Agentboard.config.settings["capture"] = { "enabled" => true, "environments" => %w[development test] }
  end

  teardown { Agentboard.config.settings.delete("capture") }

  def widget_config
    tag = response.body[/<script src="[^"]*capture\.js[^"]*" data-agentboard-capture="([^"]+)"/, 1]
    tag && JSON.parse(CGI.unescapeHTML(tag))
  end

  test "Community: free in development only; other environments need an extension" do
    assert Agentboard::Capture.enabled_for_env?("development")
    refute Agentboard::Capture.enabled_for_env?("test"), "staging-like environments are a Pro feature"
    get "/shop"
    assert_nil widget_config
    with_features(:capture)
    assert Agentboard::Capture.enabled_for_env?("test")
  end

  test "the widget is injected into host pages with route and rendered templates, never into AgentBoard" do
    with_features(:capture)
    get "/shop"
    assert_response :success
    cfg = widget_config
    assert cfg, "widget injected"
    assert_equal "shop#index", cfg["route"]
    assert_includes cfg["templates"], "app/views/shop/index.html.erb"
    assert_includes cfg["templates"], "app/views/shop/_invoice.html.erb"
    assert_equal "/agentboard/captures", cfg["endpoint"]
    assert cfg["screenshots"]
    get "/agentboard"
    refute_includes response.body, "data-agentboard-capture"
    get "/agentboard/assets/capture.js"
    assert_response :success
  end

  test "a capture becomes a ticket with sanitized context, criterion and artifact" do
    with_features(:capture)
    post "/agentboard/captures", as: :json, params: { capture: {
      title: "Total shows too many decimals", description: "See the second invoice", expected: "Totals show 2 decimals",
      kind: "bug", priority: 1, url: "http://localhost:3000/shop?token=secret123&page=2", route: "shop#index",
      viewport: { width: 1280, height: 720 }, user_agent: "Mozilla/5.0",
      templates: [ "app/views/shop/index.html.erb", "../../etc/passwd", "/abs/path.rb" ],
      console_errors: [ "TypeError: x is undefined", "token=ghp_abcdefghijklmnopqrstuvwxyz0123456789" ],
      elements: [ { selector: "[data-testid=\"invoice-INV-8\"] > span.total", template: "app/views/shop/_invoice.html.erb",
                    text: "€99.99", html: "<span class=\"total\" data-key=\"sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123\">€99.99</span>",
                    rect: { x: 10, y: 20, width: 80, height: 18 } } ] } }
    assert_response :created
    ticket = Agentboard::Ticket.find_by_key!(response.parsed_body["key"])
    assert_equal "ready", ticket.status, "the expected result became an acceptance criterion"
    assert_equal [ "Totals show 2 decimals" ], ticket.acceptance_criteria.map(&:description)
    assert_includes ticket.labels, "captured"
    assert_includes ticket.description, "app/views/shop/_invoice.html.erb"
    assert_includes ticket.description, "shop#index"
    cap = ticket.artifacts.find_by!(kind: "capture")
    assert_equal "http://localhost:3000/shop", cap.metadata["url"], "query strings (tokens) are dropped"
    assert_equal [ "app/views/shop/index.html.erb" ], cap.metadata["templates"], "unsafe paths are rejected"
    refute_includes cap.metadata.to_json, "sk-ant-api03"
    refute_includes cap.metadata.to_json, "ghp_abcdef"
    assert ticket.events.where(event_type: "ticket.captured").exists?
    get "/agentboard/tickets/#{ticket.key}"
    assert_includes response.body, "Captured from the app"
  end

  test "agents get the captured templates first in their context" do
    with_features(:capture)
    FileUtils.mkdir_p(File.join(@repo_dir, "app/views/shop"))
    File.write(File.join(@repo_dir, "app/views/shop/_invoice.html.erb"), "<div class=\"invoice\"></div>")
    git!("add", ".")
    git!("-c", "user.name=T", "-c", "user.email=t@e.com", "commit", "-qm", "views")
    post "/agentboard/captures", as: :json, params: { capture: { title: "Spacing", elements: [ { selector: ".invoice", template: "app/views/shop/_invoice.html.erb" } ] } }
    ticket = Agentboard::Ticket.find_by_key!(response.parsed_body["key"])
    pkg = Agentboard::ContextBuilder.call(ticket: ticket, repository: @project.repository)
    assert_equal "app/views/shop/_invoice.html.erb", pkg.files.first
  end

  test "the capture endpoint does not exist when capture is disabled" do
    Agentboard.config.settings["capture"]["enabled"] = false
    post "/agentboard/captures", as: :json, params: { capture: { title: "x" } }
    assert_response :not_found
  end
end
