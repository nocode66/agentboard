# Standalone upgrade harness for AT-15. Runs in its own process with its own database so
# ActiveRecord::Base is never re-pointed inside the test process.
#   ruby test/support/upgrade_harness.rb DB_PATH FROM_VERSION
require "bundler/setup"
require "active_record"
require "json"

db_path, from_version = ARGV
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db_path)
ActiveRecord::Migration.verbose = false
ctx = ActiveRecord::MigrationContext.new([ File.expand_path("../../db/migrate", __dir__) ])
conn = ActiveRecord::Base.connection
out = {}

ctx.migrate(from_version.to_i)
out["before_has_webhooks"] = conn.table_exists?("agentboard_webhook_deliveries")
now = Time.now.utc.iso8601
conn.execute("INSERT INTO agentboard_projects (id, key, name, root_path, default_branch, settings, ticket_counter, created_at, updated_at) " \
             "VALUES ('p1', 'OLD', 'Legacy', '/tmp/legacy', 'main', '{}', 1, '#{now}', '#{now}')")
conn.execute("INSERT INTO agentboard_tickets (id, project_id, number, title, description, kind, status, priority, position, labels, fencing_counter, lock_version, created_at, updated_at) " \
             "VALUES ('t1', 'p1', 1, 'Legacy ticket', 'from 0.1', 'task', 'review', 1, 0, '[]', 3, 7, '#{now}', '#{now}')")
payload = { "input_tokens" => 10, "output_tokens" => 5, "reported_cost_usd" => 0.42 }.to_json
conn.execute("INSERT INTO agentboard_events (id, project_id, aggregate_type, aggregate_id, sequence, event_type, schema_version, source, provenance, " \
             "occurred_at, received_at, payload, correlation_id, created_at, updated_at) VALUES ('e1', 'p1', 'execution', 'x1', 1, " \
             "'agent.execution.usage', 1, 'provider.claude', 'provider_reported', '#{now}', '#{now}', '#{payload}', 'c-1', '#{now}', '#{now}')")

ctx.migrate
out["pending_after"] = ctx.needs_migration?
out["after_has_webhooks"] = conn.table_exists?("agentboard_webhook_deliveries")
out["ticket"] = conn.select_one("SELECT title, status, lock_version, fencing_counter FROM agentboard_tickets WHERE id = 't1'")
out["event"] = conn.select_one("SELECT event_type, schema_version, payload FROM agentboard_events WHERE id = 'e1'")
ctx.rollback(1)
out["after_rollback_has_tickets"] = conn.table_exists?("agentboard_tickets")
puts JSON.generate(out)
