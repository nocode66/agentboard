require "test_helper"

# AT-15: an installation created with the v0.1.0 migrations keeps tickets and events intact
# after upgrading to the current schema, and historical events stay readable via upcasters.
class UpgradeTest < ActiveSupport::TestCase
  V0_1_LAST_MIGRATION = 2026_11_14_000002

  test "AT-15: upgrade from v0.1.0 preserves data; historical events stay readable" do
    db = File.join(Dir.mktmpdir("agentboard-upgrade"), "legacy.sqlite3")
    out, err, st = Open3.capture3({ "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__) }, RbConfig.ruby,
                                  File.expand_path("../support/upgrade_harness.rb", __dir__), db, V0_1_LAST_MIGRATION.to_s)
    assert st.success?, err
    r = JSON.parse(out.lines.last)
    refute r["before_has_webhooks"], "started at the v0.1.0 schema"
    assert r["after_has_webhooks"]
    refute r["pending_after"]
    assert_equal [ "Legacy ticket", "review", 7, 3 ], r["ticket"].values_at("title", "status", "lock_version", "fencing_counter")
    assert_equal 1, r["event"]["schema_version"], "historical events are never rewritten"
    upcast = Agentboard::EventSchema.upcast(r["event"]["event_type"], r["event"]["schema_version"], JSON.parse(r["event"]["payload"]))
    assert_equal({ "input_tokens" => 10, "output_tokens" => 5, "reported_cost" => 0.42, "currency" => "USD" }, upcast)
    assert r["after_rollback_has_tickets"], "rolling back the newest migration keeps ticket data"
  end

  test "new events are written at the current schema version and read back unchanged" do
    t = create_ticket
    e = Agentboard::EventStore.append!(type: "agent.execution.usage", aggregate: t, ticket: t, payload: { reported_cost: nil, currency: nil })
    assert_equal 2, e.schema_version
    assert_equal({ "reported_cost" => nil, "currency" => nil }, e.data)
  end
end
