require "test_helper"

class ContainerSandboxTest < ActiveSupport::TestCase
  setup do
    Agentboard.config.settings["security"]["sandbox"] = "container"
    Agentboard.config.settings["sandbox"] = { "image" => "ruby:3.4-slim" }
  end

  teardown do
    Agentboard.config.settings["security"]["sandbox"] = "none"
    Agentboard.config.settings.delete("sandbox")
  end

  test "verification argv is wrapped with default-deny network and least privilege" do
    argv = Agentboard::ContainerSandbox.wrap(%w[bin/rails test], workdir: @repo_dir, env: { "CI" => "1", "bad key" => "x" }, name: "agentboard-x")
    joined = argv.join(" ")
    assert_equal "docker", argv.first
    assert_includes joined, "--network none"
    assert_includes joined, "--cap-drop ALL"
    assert_includes joined, "--security-opt no-new-privileges"
    assert_includes joined, "--user #{Process.uid}:#{Process.gid}"
    assert_includes joined, "-v #{File.realpath(@repo_dir)}:#{File.realpath(@repo_dir)}"
    assert_includes joined, "-w #{File.realpath(@repo_dir)}"
    assert_equal %w[ruby:3.4-slim bin/rails test], argv.last(3)
    refute_includes joined, "bad key", "only well-formed env names are forwarded"
    assert_equal 1, argv.count { |a| a == "-v" }, "the repository itself is the only mount (its .git is inside it)"
  end

  test "misconfiguration is rejected" do
    Agentboard.config.settings["sandbox"] = { "image" => "" }
    assert_raises(Agentboard::Error) { Agentboard::ContainerSandbox.wrap(%w[true], workdir: @repo_dir) }
    Agentboard.config.settings["sandbox"] = { "image" => "x", "network" => "host; rm -rf /" }
    assert_raises(Agentboard::Error) { Agentboard::ContainerSandbox.wrap(%w[true], workdir: @repo_dir) }
  end

  test "real providers stay refused under the container sandbox; verification needs a running runtime" do
    t = create_ticket
    assert_error_code("CAPABILITY_UNAVAILABLE") { Agentboard::Executions.enforce_isolation_policy!("claude") }
    unless Agentboard::ContainerSandbox.available?
      e = run_execution(Agentboard::Executions.enqueue!(ticket: t, provider_key: "fake", actor: human))
      assert_equal "failed", e.status
      assert_match(/not running/, e.failure_message)
    end
  end

  test "verification inside a real container (runs only when Docker is available)" do
    skip "container runtime not running" unless Agentboard::ContainerSandbox.available?

    Agentboard.config.settings["sandbox"] = { "image" => "ruby:3.4-slim" }
    outcome = Agentboard::Verification::Runner.new(catalog: Agentboard.config.verification_catalog).run("rails_test", chdir: @repo_dir)
    assert_equal "passed", outcome.status
  end
end
