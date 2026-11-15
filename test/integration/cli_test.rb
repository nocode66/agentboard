require "test_helper"

# Exercises the real executable the way providers invoke it (separate process).
class CliTest < ActiveSupport::TestCase
  DUMMY = File.expand_path("../dummy", __dir__)

  def cli(*args, stdin: "", license: nil)
    env = { "RAILS_ENV" => "test", "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__), "AGENTBOARD_LICENSE" => license }
    Open3.capture3(env, RbConfig.ruby, "-rbundler/setup", File.expand_path("../../exe/agentboard", __dir__), *args, "--root", DUMMY,
                   stdin_data: stdin, chdir: DUMMY)
  end

  test "hook ingest reads stdin before boot and records a corroborated session" do
    _out, err, st = cli("hook", "ingest", "--provider", "claude", "--event", "SessionStart",
                        stdin: JSON.generate("session_id" => "cli-hook-1", "hook_event_name" => "SessionStart"))
    assert st.success?, err
    session = Agentboard::AgentSession.find_by(external_session_id: "cli-hook-1")
    assert session, "hook payload must be ingested (stdin read before Rails boot)"
    assert_equal "hook", session.trust_level
  end

  test "codex notify passes the payload as the last argument" do
    payload = JSON.generate("type" => "agent-turn-complete", "thread-id" => "cli-codex-1", "turn-id" => "1")
    _o, err, st = cli("hook", "ingest", "--provider", "codex", "--event", "agent-turn-complete", payload)
    assert st.success?, err
    assert Agentboard::AgentSession.exists?(external_session_id: "cli-codex-1")
  end

  test "hook ingest never fails the provider, even with garbage input" do
    _o, _e, st = cli("hook", "ingest", "--provider", "claude", "--event", "Stop", stdin: "not json")
    assert st.success?
  end

  test "ticket commands and documented exit codes" do
    out, _e, st = cli("ticket", "create", "From CLI", "--criteria", "works", "--ready", "--json")
    assert st.success?
    key = JSON.parse(out)["key"]
    out, _e, st = cli("ticket", "show", key, "--json")
    assert st.success?
    assert_equal "ready", JSON.parse(out)["status"]
    _o, _e, st = cli("ticket", "show", "NOPE-999")
    assert_equal 3, st.exitstatus
    _o, _e, st = cli("ticket", "move", key, "done")
    assert_equal 2, st.exitstatus
  ensure
    Agentboard::Project.where(root_path: DUMMY).destroy_all rescue nil
  end
end
