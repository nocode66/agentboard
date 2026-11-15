ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__), File.expand_path("../db/migrate", __dir__) ]
require "rails/test_help"
require "tmpdir"
require "open3"

# Apply engine migrations directly (works identically on SQLite and PostgreSQL and does
# not depend on a schema.rb dumped from another adapter).
migration_context = ActiveRecord::Base.connection_pool.migration_context
migration_context.migrate if migration_context.needs_migration?

# Test-only licence signing key for AgentBoard Pro (trusted only when RAILS_ENV=test).
TEST_PRO_PRIVATE_KEY, test_pub = Agentboard::Pro::License.generate_keypair
ENV["AGENTBOARD_PRO_TEST_PUBLIC_KEY"] = test_pub
ENV.delete("AGENTBOARD_LICENSE")
Agentboard::Pro::License.trusted_keys = nil
Agentboard::Pro::License.search_home = false

module AgentboardTestHelpers
  TABLES = %w[
    agentboard_webhook_deliveries agentboard_idempotency_keys agentboard_usage_records agentboard_verification_results agentboard_approvals
    agentboard_artifacts agentboard_outbox_messages agentboard_events agentboard_executions agentboard_workflow_steps
    agentboard_workflow_runs agentboard_workflow_definitions agentboard_ticket_leases agentboard_session_ticket_links
    agentboard_agent_sessions agentboard_agent_profiles agentboard_comments agentboard_acceptance_criteria
    agentboard_ticket_dependencies agentboard_tickets agentboard_milestones agentboard_repository_snapshots agentboard_projects
  ].freeze

  def self.included(base)
    base.class_eval do
      # Runtime code uses separate threads/connections and real subprocesses, so tests commit
      # for real and clean up explicitly.
      self.use_transactional_tests = false
      setup :agentboard_setup
      teardown :agentboard_teardown
    end
  end

  def agentboard_setup
    clean_tables!
    @repo_dir = File.realpath(Dir.mktmpdir("agentboard-repo"))
    git!("init", "-q", "-b", "main")
    File.write(File.join(@repo_dir, "README.md"), "# Demo app\n")
    FileUtils.mkdir_p(File.join(@repo_dir, "app/models"))
    File.write(File.join(@repo_dir, "app/models/invoice.rb"), "class Invoice\n  def total = 0\nend\n")
    git!("add", ".")
    git!("-c", "user.name=Test", "-c", "user.email=t@example.com", "commit", "-q", "-m", "initial")
    Agentboard.reset_configuration!
    Agentboard.config.root = @repo_dir
    Agentboard.config.update(
      "project" => { "name" => "Demo", "key" => "AB" },
      "runtime" => { "cancel_grace_seconds" => 1, "poll_interval" => 0.05, "socket_dir" => File.join(Dir.tmpdir, "abt-#{SecureRandom.hex(3)}") },
      "verification_commands" => { "rails_test" => { "argv" => [ "ruby", "-e", "exit 0" ], "timeout_seconds" => 30, "required" => true } }
    )
    Agentboard.config.settings["verification_commands"] = { "rails_test" => { "argv" => [ "ruby", "-e", "exit 0" ], "timeout_seconds" => 30, "required" => true } }
    @project = Agentboard::Project.create!(name: "Demo", key: "AB", root_path: @repo_dir, default_branch: "main")
  end

  # Installs a signed test licence for the given Pro features (all by default).
  def with_pro(*features, days: 30)
    features = Agentboard::Pro::License::ALL_FEATURES if features.empty?
    ENV["AGENTBOARD_LICENSE"] = Agentboard::Pro::License.issue(private_key_pem: TEST_PRO_PRIVATE_KEY, licensee: "Test Co",
                                                                features: features, expires_at: Time.now.utc + days * 86_400)
    Agentboard::Pro::License.reset!
    ENV["AGENTBOARD_LICENSE"]
  end

  def without_pro
    ENV.delete("AGENTBOARD_LICENSE")
    Agentboard::Pro::License.reset!
  end

  def agentboard_teardown
    without_pro
    Dir.glob(File.join(@repo_dir, ".agentboard/worktrees/*")).each { |w| system("git", "-C", @repo_dir, "worktree", "remove", "--force", w, out: File::NULL, err: File::NULL) }
    FileUtils.rm_rf(@repo_dir) if @repo_dir
    clean_tables!
  end

  def clean_tables!
    conn = ActiveRecord::Base.connection
    conn.disable_referential_integrity { TABLES.each { |t| conn.execute("DELETE FROM #{t}") } }
  end

  def git!(*args)
    out, err, st = Open3.capture3("git", *args, chdir: @repo_dir)
    raise "git #{args.join(" ")} failed: #{err}" unless st.success?

    out
  end

  def commit_file!(name, content, message: "change")
    File.write(File.join(@repo_dir, name), content)
    git!("add", name)
    git!("-c", "user.name=Test", "-c", "user.email=t@example.com", "commit", "-q", "-m", message)
    git!("rev-parse", "HEAD").strip
  end

  def human = Agentboard::Authorization.local_human("alice")
  def system_actor = Agentboard::Authorization.system_actor

  def create_ticket(title: "Add invoice totals", criteria: [ "Invoice#total sums line items" ], status: "ready", **opts)
    Agentboard::Tickets.create!(project: @project, actor: human, title: title, criteria: criteria, status: status, **opts)
  end

  def agent_session(provider: "claude", trust: "mcp_stdio")
    Agentboard::AgentSession.create!(project: @project, provider_key: provider, trust_level: trust, state: "active")
  end

  def assert_error_code(code, &block)
    error = assert_raises(Agentboard::Error, &block)
    assert_equal code, error.code, "expected #{code}, got #{error.code}: #{error.message}"
    error
  end

  # Runs an execution synchronously through the real runner (fake provider subprocess).
  def run_execution(execution)
    Agentboard::Runtime::ExecutionRunner.new(execution).call
    execution.reload
  end
end

class ActiveSupport::TestCase
  include AgentboardTestHelpers
end
