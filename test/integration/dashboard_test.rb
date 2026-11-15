require "test_helper"

class DashboardTest < ActionDispatch::IntegrationTest
  include Agentboard::Engine.routes.url_helpers

  setup { host! "localhost" }

  test "AT-01: dashboard pages render for local requests" do
    t = create_ticket
    run_execution(Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human))
    paths = [ "/agentboard", "/agentboard/tickets", "/agentboard/tickets/AB-1", "/agentboard/tickets/new", "/agentboard/executions",
              "/agentboard/executions/#{t.executions.first.id}", "/agentboard/approvals", "/agentboard/workflows", "/agentboard/agents",
              "/agentboard/analytics", "/agentboard/settings", "/agentboard/pulse", "/agentboard/milestones" ]
    paths.each do |p|
      get p
      assert_response :success, "#{p} → #{response.status}"
    end
    get "/agentboard/assets/agentboard.css"
    assert_response :success
    get "/agentboard/assets/turbo.js"
    assert_response :success
  end

  test "non-local requests are refused by default" do
    get "/agentboard", env: { "REMOTE_ADDR" => "203.0.113.9" }
    assert_response :forbidden
  end

  test "create ticket, drag to a column (server-validated), comment, approve" do
    post "/agentboard/tickets", params: { ticket: { title: "From UI", description: "d", criteria: "works\n", kind: "feature", priority: 1, status: "backlog" } }
    assert_response :redirect
    t = Agentboard::Ticket.find_by!(title: "From UI")
    post "/agentboard/tickets/#{t.key}/move", params: { to: "ready" }, as: :json
    assert_response :success
    assert_equal "ready", t.reload.status
    post "/agentboard/tickets/#{t.key}/move", params: { to: "done" }, as: :json
    assert_response :unprocessable_entity
    assert_equal "INVALID_TRANSITION", response.parsed_body.dig("error", "code")
    post "/agentboard/tickets/#{t.key}/comments", params: { comment: { body: "looks good" } }
    assert_equal 1, t.comments.count
  end

  test "workflow YAML validation endpoint" do
    post "/agentboard/workflows/validate", params: { yaml: "version: 1\nname: x\nsteps:\n  - { id: a, type: condition }\n" }, as: :json
    assert response.parsed_body["ok"]
    post "/agentboard/workflows/validate", params: { yaml: "version: 2" }, as: :json
    assert_response :unprocessable_entity
  end
end

class IpcTest < ActiveSupport::TestCase
  test "runtime IPC authenticates every request and rejects bad tokens" do
    sup = Agentboard::Runtime::Supervisor.new
    server = Agentboard::Runtime::IPC::Server.new(handler: Agentboard::Runtime::IpcHandler.new(sup)).start
    paths = Agentboard::Runtime::IPC.paths
    assert_equal "600", format("%o", File.stat(paths[:socket]).mode & 0o777)
    assert_equal "700", format("%o", File.stat(paths[:dir]).mode & 0o777)
    client = Agentboard::Runtime::IPC::Client.new
    health = client.call("runtime.health")
    assert health["ok"], health.inspect
    assert_equal Agentboard::VERSION, health.dig("data", "version")

    create_ticket
    enq = client.call("execution.enqueue", { "ticket_key" => "AB-1", "provider" => "fake", "idempotency_key" => "k1" })
    again = client.call("execution.enqueue", { "ticket_key" => "AB-1", "provider" => "fake", "idempotency_key" => "k1" })
    assert_equal enq.dig("data", "execution_id"), again.dig("data", "execution_id")

    UNIXSocket.open(paths[:socket].to_s) do |sock|
      Agentboard::Runtime::IPC.write_frame(sock, { "protocol" => 1, "op" => "runtime.health", "token" => "forged" })
      assert_equal "UNAUTHORIZED", Agentboard::Runtime::IPC.read_frame(sock).dig("error", "code")
    end
  ensure
    server&.stop
  end
end
