require "tmpdir"
require "open3"
require "fileutils"
require "securerandom"

module Agentboard
  # Test kit for AgentBoard itself and for extensions (agentboard-pro, third-party
  # adapters). Opt in from your test_helper:
  #
  #   require "agentboard/testing"
  #   Agentboard::Testing.prepare_database!
  #   class ActiveSupport::TestCase
  #     include Agentboard::Testing::Helpers
  #   end
  #
  # Every test gets a throwaway Git repository, a fresh configuration and a project.
  module Testing
    TABLES = %w[
      agentboard_webhook_deliveries agentboard_idempotency_keys agentboard_usage_records agentboard_verification_results agentboard_approvals
      agentboard_artifacts agentboard_outbox_messages agentboard_events agentboard_executions agentboard_workflow_steps
      agentboard_workflow_runs agentboard_workflow_definitions agentboard_ticket_leases agentboard_session_ticket_links
      agentboard_agent_sessions agentboard_agent_profiles agentboard_comments agentboard_acceptance_criteria
      agentboard_ticket_dependencies agentboard_tickets agentboard_milestones agentboard_repository_snapshots agentboard_projects
    ].freeze

    # Applies the engine migrations (works the same on SQLite and PostgreSQL and does not
    # depend on an adapter-specific schema.rb).
    def self.prepare_database!
      paths = ActiveRecord::Migrator.migrations_paths | [ Agentboard::Engine.root.join("db/migrate").to_s ]
      ActiveRecord::Migrator.migrations_paths = paths
      context = ActiveRecord::Base.connection_pool.migration_context
      ActiveRecord::Migration.verbose = false
      context.migrate if context.needs_migration?
    end

    module Helpers
      def self.included(base)
        base.class_eval do
          # Runtime code uses separate threads/connections and real subprocesses, so tests
          # commit for real and clean up explicitly.
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
          "runtime" => { "cancel_grace_seconds" => 1, "poll_interval" => 0.05, "socket_dir" => File.join(Dir.tmpdir, "abt-#{SecureRandom.hex(3)}") }
        )
        Agentboard.config.settings["verification_commands"] = { "rails_test" => { "argv" => [ "ruby", "-e", "exit 0" ], "timeout_seconds" => 30, "required" => true } }
        @project = Agentboard::Project.create!(name: "Demo", key: "AB", root_path: @repo_dir, default_branch: "main")
      end

      # Enables extension features without a commercial extension (for testing gated code
      # paths and third-party extensions).
      def with_features(*keys)
        Agentboard::Extensions.register("agentboard-testing", version: Agentboard::VERSION, features: keys.map(&:to_sym))
      end

      def agentboard_teardown
        Agentboard::Extensions.unregister("agentboard-testing")
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
  end
end
