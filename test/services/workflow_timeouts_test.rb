require "test_helper"
require "socket"

class WorkflowTimeoutsAndExternalTest < ActiveSupport::TestCase
  setup { with_pro(:advanced_workflows) }

  def drive(run, until_status:, timeout: 40)
    deadline = Time.now + timeout
    threads = []
    loop do
      Agentboard::WorkflowEngine.advance(run.reload)
      Agentboard::Execution.where(status: "queued").find_each do |e|
        threads << Thread.new(e.id) { |id| ActiveRecord::Base.connection_pool.with_connection { Agentboard::Runtime::ExecutionRunner.new(Agentboard::Execution.find(id)).call } }
      end
      break if Array(until_status).include?(run.reload.status) || Time.now > deadline

      sleep 0.2
    end
    threads.each { |t| t.join(10) }
    run.reload
  end

  test "a step that exceeds its own timeout is cancelled and fails with execution_timeout" do
    t = create_ticket
    yaml = "version: 1\nname: slowpoke\nsteps:\n  - { id: slow, type: agent, provider: fake, action: implement, timeout_seconds: 1, config: { scenario: slow } }\n"
    d = Agentboard::WorkflowEngine.register!(project: @project, yaml: yaml)
    profile = Agentboard::AgentProfile.default_for(@project, "fake")
    profile.update!(config: { "scenario" => "slow" })
    run = drive(Agentboard::WorkflowEngine.start!(definition: d, ticket: t, actor: human), until_status: %w[failed succeeded])
    step = run.current_steps["slow"]
    assert_equal "failed", step.status
    assert_match(/exceeded 1s/, step.error)
    assert_includes %w[cancelled failed], step.executions.first.reload.status
  ensure
    profile&.update!(config: {})
  end

  test "external steps call only configured integrations with a signed body" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    received = Queue.new
    listener = Thread.new do
      client = server.accept
      headers = {}
      while (line = client.gets) && line != "\r\n"
        k, v = line.split(": ", 2)
        headers[k.downcase] = v&.strip
      end
      body = client.read(headers["content-length"].to_i)
      received << [ headers, body ]
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
      client.close
    end
    ENV["AB_TEST_INTEGRATION_SECRET"] = "s3cret"
    Agentboard.config.settings["integrations"] = { "notify" => { "url" => "http://127.0.0.1:#{port}/hook", "secret_env" => "AB_TEST_INTEGRATION_SECRET" } }
    t = create_ticket
    d = Agentboard::WorkflowEngine.register!(project: @project, yaml: "version: 1\nname: notify\nsteps:\n  - { id: tell, type: external, integration: notify }\n")
    run = drive(Agentboard::WorkflowEngine.start!(definition: d, ticket: t, actor: human), until_status: %w[succeeded failed], timeout: 15)
    assert_equal "succeeded", run.status
    headers, body = received.pop
    assert_equal "AB-1", JSON.parse(body)["ticket_key"]
    assert_equal "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "s3cret", body)}", headers["x-agentboard-signature"]

    err = assert_raises(Agentboard::Error) { Agentboard::Workflows::Definition.parse_yaml("version: 1\nname: x\nsteps:\n  - { id: a, type: external, integration: unknown }\n") }
    assert_match(/not configured/, err.message)
  ensure
    listener&.kill
    server&.close
    ENV.delete("AB_TEST_INTEGRATION_SECRET")
    Agentboard.config.settings.delete("integrations")
  end
end
