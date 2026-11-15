require "test_helper"
require "socket"

class EgressProxyTest < ActiveSupport::TestCase
  test "only allowlisted CONNECT targets are tunnelled" do
    upstream = TCPServer.new("127.0.0.1", 0)
    echo = Thread.new { c = upstream.accept; c.write("pong:#{c.gets}"); c.close }
    log = StringIO.new
    proxy = Agentboard::EgressProxy.new(allow: [ "127.0.0.1:#{upstream.addr[1]}" ], port: 0, bind: "127.0.0.1", log: log).start

    s = TCPSocket.new("127.0.0.1", proxy.port)
    s.write("CONNECT 127.0.0.1:#{upstream.addr[1]} HTTP/1.1\r\nHost: x\r\n\r\n")
    assert_match(/200/, s.gets)
    s.gets
    s.write("ping\n")
    assert_equal "pong:ping\n", s.read
    s.close

    denied = TCPSocket.new("127.0.0.1", proxy.port)
    denied.write("CONNECT evil.example.com:443 HTTP/1.1\r\n\r\n")
    assert_match(/403/, denied.gets)
    plain = TCPSocket.new("127.0.0.1", proxy.port)
    plain.write("GET http://evil.example.com/ HTTP/1.1\r\n\r\n")
    assert_match(/405/, plain.gets)
    sleep 0.1
    assert_includes log.string, "\"decision\":\"denied\""
  ensure
    proxy&.stop
    echo&.kill
    upstream&.close
  end
end

class AgentContainerTest < ActiveSupport::TestCase
  setup do
    @state = File.join(ENV.fetch("TMPDIR", "/tmp"), "agentboard-fake-docker")
    FileUtils.rm_rf(@state)
    FileUtils.mkdir_p(@state)
    @log = File.join(@state, "calls.jsonl")
    Agentboard.config.settings["security"]["sandbox"] = "container"
    Agentboard.config.settings["sandbox"] = { "runtime" => File.expand_path("../support/fake_docker", __dir__), "image" => "agent:test",
                                              "agents" => true, "agent_image" => "agent:test", "credential_env" => %w[ANTHROPIC_API_KEY] }
  end

  teardown do
    Agentboard.config.settings["security"]["sandbox"] = "none"
    Agentboard.config.settings.delete("sandbox")
    ENV.delete("ANTHROPIC_API_KEY")
  end

  def calls = File.exist?(@log) ? File.readlines(@log).map { |l| JSON.parse(l) } : []

  test "agent argv: internal network, minimal mounts, credentials forwarded by name only" do
    ENV["ANTHROPIC_API_KEY"] = "sk-ant-api03-SUPERSECRETVALUE1234567890"
    t = create_ticket
    e = Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human)
    wt = Agentboard::Git::WorktreeManager.new(repository: @project.repository, workspace: Agentboard.config.workspace_path).create!(ticket_key: t.key, attempt: 9)
    spec = Agentboard::Providers::LaunchSpec.new(argv: %w[claude -p], env: { "MCP_TOOL_TIMEOUT" => "1" }, chdir: wt.path,
                                                 passthrough_env: %w[ANTHROPIC_API_KEY OPENAI_API_KEY])
    argv = Agentboard::AgentContainer.wrap(spec, execution: e, name: "x")
    joined = argv.join(" ")
    assert_includes joined, "--network #{Agentboard::AgentContainer.network_name}"
    assert_includes joined, "--read-only"
    assert_includes joined, "--cap-drop ALL"
    assert_includes joined, "HTTPS_PROXY=http://agentboard-egress:3128"
    assert_includes argv, "ANTHROPIC_API_KEY", "credential forwarded by name"
    refute_includes joined, "SUPERSECRETVALUE", "secret values never appear in argv"
    refute_includes argv, "OPENAI_API_KEY", "only allowlisted and present credentials are forwarded"
    mounts = argv.each_cons(2).select { |a, _| a == "-v" }.map(&:last)
    assert_equal 2, mounts.size, "only the worktree and the git directory are mounted"
    assert mounts.all? { |m| src, dst, = m.split(":"); src == dst }, "mounted at identical paths so git works"
    refute(mounts.any? { |m| m.start_with?(Dir.home + ":") }, "the home directory is never mounted")
  end

  test "end to end: the agent runs through the container runtime and commits from inside" do
    t = create_ticket
    e = run_execution(Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human))
    assert_equal "completed", e.status, e.failure_message
    assert_equal "container", e.metadata["isolation"]
    runs = calls.select { |c| c.first == "run" && c.include?("--rm") }
    agent_run = runs.find { |c| c.include?("agent:test") && c.include?("--network") && c.include?(Agentboard::AgentContainer.network_name) }
    assert agent_run, "agent launched inside a container on the internal network"
    assert calls.any? { |c| c[0, 2] == %w[network create] && c.include?("--internal") }, "internal network created"
    assert calls.any? { |c| c.first == "run" && c.include?("-d") && c.include?("--network-alias") }, "egress proxy started"
    verify_run = runs.find { |c| c.include?("--network") && c[c.index("--network") + 1] == "none" }
    assert verify_run, "verification ran in a network-less container"
    assert e.head_sha.present?
    assert e.events.where(event_type: "agent.execution.container_started").exists?
  end

  test "cancelling removes the container (killing the CLI is not enough)" do
    t = create_ticket
    e = Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human, metadata: { "scenario" => "slow" })
    runner = Thread.new { ActiveRecord::Base.connection_pool.with_connection { Agentboard::Runtime::ExecutionRunner.new(Agentboard::Execution.find(e.id)).call } }
    sleep 0.1 until e.reload.status == "running" || !runner.alive?
    Agentboard::Executions.request_cancel!(execution: e, actor: human)
    runner.join(15)
    assert_equal "cancelled", e.reload.status
    assert calls.any? { |c| c[0, 2] == [ "rm", "-f" ] && c.last == e.metadata["container"] }
  end

  test "real agents may run without trusted_local_execution only when containers are on" do
    refute Agentboard.config.security["trusted_local_execution"]
    assert_nothing_raised { Agentboard::Executions.enforce_isolation_policy!("claude") }
    Agentboard.config.settings["sandbox"]["runtime"] = "/nonexistent/docker"
    assert_error_code("CAPABILITY_UNAVAILABLE") { Agentboard::Executions.enforce_isolation_policy!("claude") }
  end

  test "providers drop host-only safeguards only inside containers" do
    t = create_ticket
    e = Agentboard::Execution.new(ticket: t, provider_key: "claude", metadata: { "isolation" => "container" }, agent_profile: Agentboard::AgentProfile.new(config: {}))
    spec = Agentboard::Providers::ClaudeCode.new(settings: {}).launch_spec(execution: e, worktree: "/tmp/wt", context_path: "x", prompt: "p")
    assert_equal "bypassPermissions", spec.argv[spec.argv.index("--permission-mode") + 1]
    refute_includes spec.argv, "--permission-prompt-tool", "no host MCP bridge inside the container"
    codex = Agentboard::Providers::Codex.new(settings: {}).launch_spec(execution: e, worktree: "/tmp/wt", context_path: "x", prompt: "p")
    assert_equal "danger-full-access", codex.argv[codex.argv.index("--sandbox") + 1]
    e.metadata = { "isolation" => "local" }
    e.agent_profile.config = { "permission_mode" => "bypassPermissions" }
    assert_error_code("POLICY_DENIED") { Agentboard::Providers::ClaudeCode.new(settings: {}).launch_spec(execution: e, worktree: "/tmp", context_path: "x", prompt: "p") }
  end
end

class CredentialAliasTest < AgentContainerTest
  test "aliased credentials reach the container by name only" do
    ENV["OPENAI_API_KEY"] = "sk-proj-ALIASSECRET1234567890ABCDEFGH"
    Agentboard.config.settings["sandbox"]["credential_env"] = %w[OPENAI_API_KEY]
    t = create_ticket
    e = Agentboard::Execution.new(ticket: t, provider_key: "codex", metadata: { "isolation" => "container" }, agent_profile: Agentboard::AgentProfile.new(config: {}))
    spec = Agentboard::Providers::Codex.new(settings: {}).launch_spec(execution: e, worktree: @repo_dir, context_path: "x", prompt: "p")
    assert_equal({ "CODEX_API_KEY" => ENV["OPENAI_API_KEY"] }, Agentboard::AgentContainer.cli_env(spec))
    e.id = "01a1db00-0000-7000-8000-000000000000"
    argv = Agentboard::AgentContainer.wrap(spec, execution: e, name: "x")
    assert_includes argv, "CODEX_API_KEY"
    refute_includes argv.join(" "), "ALIASSECRET"
  ensure
    ENV.delete("OPENAI_API_KEY")
  end
end
