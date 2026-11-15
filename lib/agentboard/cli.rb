require "thor"
# Load Rails' engine base class first so the AgentBoard engine registers itself before the
# host application boots (the CLI requires agentboard before config/environment.rb).
require "rails"
require "rails/engine"
require "agentboard"

module Agentboard
  # Command-line contract (spec §12). All commands are non-interactive, accept --help,
  # and most accept --json for automation.
  #
  # Exit codes:
  #   0 success                     4 forbidden / policy denied / unauthorized
  #   1 internal error              5 conflict (version, lease, workspace)
  #   2 usage / validation error    6 provider or capability unavailable
  #   3 not found                   7 runtime daemon not running
  module CLIHelpers
    EXIT_CODES = {
      "NOT_FOUND" => 3, "VALIDATION_FAILED" => 2, "INVALID_TRANSITION" => 2, "UNAUTHORIZED" => 4, "FORBIDDEN" => 4,
      "POLICY_DENIED" => 4, "APPROVAL_REQUIRED" => 4, "VERSION_CONFLICT" => 5, "LEASE_CONFLICT" => 5, "LEASE_EXPIRED" => 5,
      "WORKSPACE_CONFLICT" => 5, "CAPABILITY_UNAVAILABLE" => 6, "PROVIDER_UNAVAILABLE" => 6, "RATE_LIMITED" => 5
    }.freeze

    def self.included(base)
      base.class_option :root, type: :string, desc: "Project root (defaults to the Git toplevel of the current directory)"
      # No default: Thor merges parent options with subcommand defaults, which would reset --json.
      base.class_option :json, type: :boolean, desc: "Machine-readable JSON output"
      base.class_eval do
        def self.exit_on_failure? = true
      end
    end

    private

    def root
      @root ||= begin
        dir = options[:root] || ENV["AGENTBOARD_ROOT"]
        unless dir
          out, _e, st = Open3.capture3("git", "rev-parse", "--show-toplevel")
          dir = st.success? ? out.strip : Dir.pwd
          # Prefer the nearest Rails app (config/environment.rb) between cwd and the git root.
          cur = Dir.pwd
          while cur.start_with?(dir)
            (dir = cur) && break if File.exist?(File.join(cur, "config", "environment.rb"))
            cur = File.dirname(cur)
          end
        end
        File.expand_path(dir)
      end
    end

    # Boots the host Rails application. stdout is redirected to stderr while booting so that
    # commands like `mcp serve` keep stdout clean for protocol frames.
    def boot!(quiet_stdout: false)
      return if @booted

      env_file = File.join(root, "config", "environment.rb")
      raise Error.not_found("No Rails application found at #{root} (config/environment.rb). Use --root.") unless File.exist?(env_file)

      ENV["RAILS_ENV"] ||= "development"
      original = $stdout
      $stdout = $stderr if quiet_stdout
      Dir.chdir(root) { require env_file }
      Agentboard.config.root = root if Agentboard.config.root.nil?
      @booted = true
    ensure
      $stdout = original if quiet_stdout && original
    end

    def actor = Authorization.local_human

    def project = @project ||= Project.current(root: Pathname.new(Agentboard.config.root_path))

    def emit(data, human = nil)
      if options[:json]
        puts JSON.pretty_generate(data.is_a?(Struct) ? data.to_h : data)
      elsif human
        human.respond_to?(:call) ? human.call : puts(human)
      end
    end

    def guard
      yield
    rescue Agentboard::Error => e
      if options[:json]
        puts JSON.pretty_generate(Result.failure(e).to_h)
      else
        warn "#{e.code}: #{e.message}"
        Array(e.details[:missing]).each { |m| warn "  • #{m}" }
      end
      exit(EXIT_CODES.fetch(e.code, 1))
    rescue Thor::Error
      raise
    rescue StandardError => e
      warn "INTERNAL_ERROR: #{e.class}: #{Redactor.redact(e.message)}"
      warn e.backtrace.first(5).join("\n") if ENV["AGENTBOARD_DEBUG"]
      exit 1
    end

    def ticket!(key) = Ticket.find_by_key!(key.to_s.upcase, project: project)

    def table(rows, headers)
      widths = headers.each_index.map { |i| ([ headers[i].to_s.size ] + rows.map { |r| r[i].to_s.size }).max.clamp(0, 60) }
      line = ->(cols) { cols.each_with_index.map { |c, i| c.to_s[0, 60].ljust(widths[i]) }.join("  ") }
      puts line.(headers)
      puts widths.map { |w| "─" * w }.join("  ")
      rows.each { |r| puts line.(r) }
    end
  end

  class DaemonCLI < Thor
    include CLIHelpers
    namespace :daemon

    desc "start", "Start the runtime daemon (separate from the web server)"
    method_option :foreground, type: :boolean, default: false, aliases: "-f", desc: "Run in the foreground"
    def start
      guard do
        boot!
        status = Runtime::DaemonControl.status
        if status[:running]
          emit({ running: true, pid: status[:pid] }, "AgentBoard daemon already running (pid #{status[:pid]})")
          return
        end
        if options[:foreground]
          run_foreground
        else
          paths = Runtime::IPC.paths
          Runtime::IPC.ensure_private_dir!(paths[:dir])
          log = File.open(paths[:log], "a", 0o600)
          pid = ::Process.spawn(RbConfig.ruby, File.expand_path("../../exe/agentboard", __dir__), "daemon", "start", "--foreground", "--root", root,
                                out: log, err: log, in: File::NULL, pgroup: true, chdir: root)
          ::Process.detach(pid)
          deadline = Time.now + 20
          sleep 0.2 until Runtime::DaemonControl.status[:running] || Time.now > deadline
          st = Runtime::DaemonControl.status
          raise Error.provider_unavailable("Daemon failed to start; see #{paths[:log]}") unless st[:running]

          emit({ running: true, pid: st[:pid], log: paths[:log].to_s }, "AgentBoard daemon started (pid #{st[:pid]}) · logs: #{paths[:log]}")
        end
      end
    end

    desc "stop", "Stop the runtime daemon gracefully"
    def stop
      guard do
        boot!
        stopped = Runtime::DaemonControl.stop
        emit({ stopped: stopped }, stopped ? "AgentBoard daemon stopped" : "Daemon was not running")
      end
    end

    desc "restart", "Restart the runtime daemon (running attempts are reconciled as interrupted)"
    def restart
      stop
      @booted = true
      invoke :start, [], options.merge(foreground: false)
    end

    desc "status", "Show runtime daemon status"
    def status
      guard do
        boot!
        st = Runtime::DaemonControl.status
        emit(st, -> {
          puts st[:running] ? "running · pid #{st[:pid]} · active #{st.dig(:health, "active")} · queued #{st.dig(:health, "queued")}" : "not running#{" (stale pid file)" if st[:stale_pid_file]}"
        })
        exit 7 unless st[:running]
      end
    end

    private

    def run_foreground
      Extensions.run(:runtime_start)
      lock = Runtime::DaemonControl.write_pid!
      logger = Logger.new($stdout, progname: "agentboard")
      logger.formatter = JsonLogFormatter.new(component: "runtime") unless ENV["AGENTBOARD_LOG_FORMAT"] == "text"
      Agentboard.logger = logger
      supervisor = Runtime::Supervisor.new(logger: logger)
      server = Runtime::IPC::Server.new(handler: Runtime::IpcHandler.new(supervisor), logger: logger).start
      %w[TERM INT].each { |sig| trap(sig) { supervisor.stop! } }
      logger.info("AgentBoard runtime #{Agentboard::VERSION} started (pid #{::Process.pid}, root #{root})")
      HookIngestion.replay_spool!(root: root) rescue nil
      supervisor.run
    ensure
      server&.stop
      if lock
        File.delete(Runtime::IPC.paths[:pid]) rescue nil
        lock.close
      end
      logger&.info("AgentBoard runtime stopped")
    end
  end

  class ProviderCLI < Thor
    include CLIHelpers
    namespace :provider

    desc "list", "List providers and detected capabilities"
    def list
      guard do
        boot!
        probes = Providers.registry.all.map(&:probe)
        emit(probes.map(&:to_h), -> {
          table(probes.map { |p| [ p.provider, p.installed ? (p.version || "?") : "—", p.validation, p.supported_capabilities.join(",") ] },
                %w[PROVIDER VERSION STATUS CAPABILITIES])
        })
      end
    end

    desc "setup NAME", "Configure passive integration (MCP + hooks) for claude, codex or cursor"
    method_option :notify, type: :boolean, default: false, desc: "Codex: also install the global notify hook (opt-in)"
    def setup(name)
      guard do
        boot!
        provider = Providers.registry.fetch(name)
        probe = provider.probe
        raise Error.provider_unavailable("#{provider.display_name} is not installed") unless probe.installed || name == "cursor"

        result = name.to_s == "codex" ? provider.install_passive_hooks(project: project, root: root, notify: options[:notify]) :
                                         provider.install_passive_hooks(project: project, root: root)
        emit(result.to_h, -> {
          puts "#{provider.display_name} #{probe.version} — passive integration"
          result.changes.each { |c| puts "  #{c[:action].to_s.ljust(9)} #{c[:path]} #{Array(c[:keys]).join(".")} #{Array(c[:events]).join(", ")}".rstrip }
          result.backups.each { |b| puts "  backup    #{b}" }
          result.warnings.each { |w| puts "  note      #{w}" }
          puts "  manifest  #{ConfigEditor.manifest_path(root, provider.key)}" rescue nil
        })
      end
    end

    desc "remove NAME", "Remove AgentBoard-owned MCP/hook entries for a provider"
    def remove(name)
      guard do
        boot!
        provider = Providers.registry.fetch(name)
        removed = provider.remove_passive_hooks(project: project, root: root, manifest: Providers::ConfigEditor.read_manifest(root, provider.key))
        emit({ removed: removed }, removed.any? ? "Removed AgentBoard entries from: #{removed.join(", ")}" : "Nothing to remove")
      end
    end

    desc "doctor NAME", "Probe one provider in detail"
    def doctor(name)
      guard do
        boot!
        probe = Providers.registry.fetch(name).probe
        emit(probe.to_h, -> {
          puts "#{name}: #{probe.installed ? "installed #{probe.version}" : "not installed"} (#{probe.validation})"
          puts "capabilities: #{probe.supported_capabilities.join(", ").presence || "none"}"
          probe.diagnostics.each { |d| puts "  - #{d}" }
        })
      end
    end
  end

  class TicketCLI < Thor
    include CLIHelpers
    namespace :ticket

    desc "list", "List tickets"
    method_option :status, type: :string
    def list
      guard do
        boot!
        scope = project.tickets.includes(:project).ordered
        scope = scope.where(status: options[:status]) if options[:status]
        rows = scope.limit(200).map { |t| { key: t.key, status: t.status, priority: t.priority, title: t.title } }
        emit(rows, -> { table(rows.map(&:values), %w[KEY STATUS P TITLE]) })
      end
    end

    desc "show KEY", "Show a ticket"
    def show(key)
      guard do
        boot!
        t = ticket!(key)
        data = { key: t.key, title: t.title, status: t.status, priority: t.priority, kind: t.kind, version: t.lock_version,
                 description: t.description, criteria: t.acceptance_criteria.map { |c| { description: c.description, state: c.state } },
                 completion: CompletionPolicy.evaluate(t) }
        emit(data, -> {
          puts "#{t.key}  #{t.title}"
          puts "status #{t.status} · #{t.priority_label} · #{t.kind} · v#{t.lock_version}"
          puts "", t.description unless t.description.blank?
          puts "", "Acceptance criteria:"
          t.acceptance_criteria.each { |c| puts "  [#{c.satisfied? ? "x" : " "}] #{c.description}" }
          puts "", "Completion: #{data[:completion][:ok] ? "ready" : "blocked"}"
          data[:completion][:missing].each { |m| puts "  • #{m}" }
        })
      end
    end

    desc "create TITLE", "Create a ticket"
    method_option :description, type: :string, default: ""
    method_option :criteria, type: :array, default: [], desc: "Acceptance criteria"
    method_option :kind, type: :string, default: "task"
    method_option :priority, type: :numeric, default: 2
    method_option :ready, type: :boolean, default: false
    def create(title)
      guard do
        boot!
        t = Tickets.create!(project: project, actor: actor, title: title, description: options[:description], kind: options[:kind],
                            priority: options[:priority], criteria: options[:criteria], status: options[:ready] ? "ready" : "backlog")
        emit({ key: t.key, status: t.status }, "Created #{t.key} (#{t.status})")
      end
    end

    desc "move KEY STATUS", "Transition a ticket"
    method_option :reason, type: :string
    def move(key, status)
      guard do
        boot!
        t = Tickets.transition!(ticket: ticket!(key), to: status, actor: actor, reason: options[:reason])
        emit({ key: t.key, status: t.status }, "#{t.key} → #{t.status}")
      end
    end
  end

  class WorkflowCLI < Thor
    include CLIHelpers
    namespace :workflow

    desc "validate FILE", "Validate a workflow YAML file"
    def validate(file)
      guard do
        boot!
        d = Workflows::Definition.parse_yaml(File.read(file))
        emit({ ok: true, name: d.name, order: d.topological_order, digest: d.digest }, "✓ #{d.name}: #{d.topological_order.join(" → ")}")
      end
    end

    desc "list", "List registered workflows (syncs .agentboard/workflows first)"
    def list
      guard do
        boot!
        WorkflowEngine.sync_from_disk!(project: project)
        rows = WorkflowDefinition.where(project: project).order(:name, :version).map { |w| [ w.name, w.version, w.digest[0, 12] ] }
        emit(rows, -> { table(rows, %w[NAME VERSION DIGEST]) })
      end
    end

    map "run" => :run_workflow
    desc "run NAME KEY", "Start a workflow run for a ticket"
    def run_workflow(name, key)
      guard do
        boot!
        WorkflowEngine.sync_from_disk!(project: project)
        r = WorkflowEngine.start!(definition: WorkflowEngine.latest(project: project, name: name), ticket: ticket!(key), actor: actor)
        emit({ run_id: r.id, status: r.status }, "Started #{name} for #{key} (run #{r.id}). The daemon advances it.")
      end
    end
  end

  class McpCLI < Thor
    include CLIHelpers
    namespace :mcp

    desc "serve", "Run the MCP stdio server (stdout carries protocol frames only)"
    method_option :provider, type: :string, default: nil, desc: "Provider label for this session (claude, codex, …)"
    method_option :execution, type: :string, desc: "Bind to an AgentBoard-launched execution (permission bridge)"
    def serve
      boot!(quiet_stdout: true)
      Agentboard.logger = Logger.new($stderr, level: Logger::WARN)
      ActiveRecord::Base.logger = nil
      provider = options[:provider] || ENV["AGENTBOARD_PROVIDER"] || detect_provider
      execution = options[:execution] && Execution.find_by(id: options[:execution])
      raise Error.not_found("Execution #{options[:execution]} not found") if options[:execution] && execution.nil?

      McpServer.new(project: project, provider_key: provider, execution: execution).serve
    rescue Agentboard::Error => e
      warn "agentboard mcp: #{e.code}: #{e.message}"
      exit(CLIHelpers::EXIT_CODES.fetch(e.code, 1))
    end

    private

    def detect_provider
      return "claude" if ENV["CLAUDECODE"] || ENV["CLAUDE_CODE_ENTRYPOINT"]
      return "codex" if ENV.keys.any? { |k| k.start_with?("CODEX_") }

      "mcp"
    end
  end

  class HookCLI < Thor
    include CLIHelpers
    namespace :hook

    desc "ingest", "Ingest a provider hook payload from stdin (bounded, redacted, deduplicated)"
    method_option :provider, type: :string, required: true
    method_option :event, type: :string, required: true
    def ingest(*payload_args)
      # Read before booting Rails (app constants are not loaded yet). Bounded read.
      # Codex `notify` passes the JSON payload as the last argument instead of stdin.
      raw = payload_args.last.to_s.start_with?("{") ? payload_args.last.to_s[0, 256 * 1024] : ($stdin.tty? ? "" : $stdin.read(256 * 1024 + 1).to_s)
      begin
        Timeout.timeout(8) do
          boot!(quiet_stdout: true)
          ActiveRecord::Base.logger = nil
          HookIngestion.ingest!(provider_key: options[:provider], event_name: options[:event], raw: raw, project: project)
        end
      rescue Agentboard::Error => e
        warn "agentboard hook: #{e.code}: #{e.message}" if ENV["AGENTBOARD_DEBUG"]
      rescue StandardError, Timeout::Error => e
        warn "agentboard hook: spooling (#{e.class}: #{e.message})" if ENV["AGENTBOARD_DEBUG"]
        # App/DB unavailable: spool locally and never block the agent.
        HookIngestion.spool!(root: root, provider_key: options[:provider], event_name: options[:event], raw: raw) rescue nil
      end
      exit 0 # hooks must never fail the provider's own workflow
    end

    desc "replay", "Replay spooled hook payloads"
    def replay
      guard do
        boot!
        n = HookIngestion.replay_spool!(root: root)
        emit({ replayed: n }, "Replayed #{n} spooled hook payload(s)")
      end
    end
  end

  class SandboxCLI < Thor
    include CLIHelpers
    namespace :sandbox

    desc "init", "Write .agentboard/sandbox/Dockerfile for the agent image"
    def init
      guard do
        path = File.join(root, ".agentboard", "sandbox", "Dockerfile")
        if File.exist?(path)
          emit({ exists: path }, "#{path} already exists (left unchanged)")
        else
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, File.read(File.expand_path("templates/Dockerfile.agent", __dir__)).sub("__RUBY_VERSION__", RUBY_VERSION))
          emit({ written: path }, "Wrote #{path}. Next: agentboard sandbox build")
        end
      end
    end

    desc "build", "Build the agent image and print the config to enable container isolation"
    method_option :tag, type: :string
    def build
      guard do
        boot!
        dockerfile = File.join(root, ".agentboard", "sandbox", "Dockerfile")
        raise Error.not_found("Run `agentboard sandbox init` first") unless File.exist?(dockerfile)
        raise Error.provider_unavailable("#{AgentContainer.runtime} is not running") unless ContainerSandbox.available?

        tag = options[:tag] || "agentboard-agent:#{AgentContainer.project_id}"
        ok = system(AgentContainer.runtime, "build", "-t", tag, "-f", dockerfile, root)
        raise Error.provider_unavailable("image build failed") unless ok

        emit({ image: tag }, -> {
          puts "Built #{tag}. Enable it in .agentboard/config.yml:"
          puts "  security:\n    sandbox: container\n  sandbox:\n    agents: true\n    agent_image: #{tag}\n    image: #{tag}\n    credential_env: [ANTHROPIC_API_KEY, OPENAI_API_KEY]"
        })
      end
    end

    desc "status", "Show container isolation status (runtime, network, egress allowlist)"
    def status
      guard do
        boot!
        data = { runtime: AgentContainer.runtime, available: ContainerSandbox.available?, verification: ContainerSandbox.enabled?,
                 agents: AgentContainer.enabled?, agent_image: ContainerSandbox.settings["agent_image"], network: AgentContainer.network_name,
                 proxy: AgentContainer.proxy_name, egress_allowlist: AgentContainer.egress_allowlist }
        emit(data, -> { data.each { |k, v| puts "#{k.to_s.ljust(18)} #{v.is_a?(Array) ? v.join(", ") : v}" } })
      end
    end

    desc "down", "Remove the egress proxy and internal network of this project"
    def down
      guard do
        boot!
        Open3.capture3(AgentContainer.runtime, "rm", "-f", AgentContainer.proxy_name)
        Open3.capture3(AgentContainer.runtime, "network", "rm", AgentContainer.network_name)
        emit({ removed: [ AgentContainer.proxy_name, AgentContainer.network_name ] }, "Removed egress proxy and network")
      end
    end
  end

  class CLI < Thor
    include CLIHelpers
    package_name "agentboard"

    map %w[--version -v] => :version
    desc "version", "Print version"
    def version = puts("agentboard #{Agentboard::VERSION}")

    desc "daemon SUBCOMMAND", "Runtime daemon lifecycle (start/stop/status/restart)"
    subcommand "daemon", DaemonCLI
    desc "provider SUBCOMMAND", "Provider management (list/setup/remove/doctor)"
    subcommand "provider", ProviderCLI
    desc "ticket SUBCOMMAND", "Ticket management (list/show/create/move)"
    subcommand "ticket", TicketCLI
    desc "workflow SUBCOMMAND", "Workflows (validate/list/run)"
    subcommand "workflow", WorkflowCLI
    desc "mcp SUBCOMMAND", "MCP server"
    subcommand "mcp", McpCLI
    desc "hook SUBCOMMAND", "Provider hook ingestion"
    subcommand "hook", HookCLI
    desc "sandbox SUBCOMMAND", "Container isolation for agents (init/build/status/down)"
    subcommand "sandbox", SandboxCLI

    desc "init", "Set up .agentboard/ in this repository (idempotent, preserves existing settings)"
    def init
      guard do
        out, _e, st = Open3.capture3("git", "rev-parse", "--show-toplevel", chdir: root)
        raise Error.validation_failed("#{root} is not inside a Git repository") unless st.success?

        created = []
        %w[workflows instructions policies cache manifests].each do |d|
          path = File.join(root, ".agentboard", d)
          next if File.directory?(path)

          FileUtils.mkdir_p(path)
          created << ".agentboard/#{d}/"
        end
        config = File.join(root, ".agentboard", "config.yml")
        unless File.exist?(config)
          File.write(config, File.read(File.expand_path("../generators/agentboard/install/templates/config.yml", __dir__)))
          created << ".agentboard/config.yml"
        end
        wf = File.join(root, ".agentboard", "workflows", "feature_delivery.yml")
        unless File.exist?(wf)
          File.write(wf, File.read(File.expand_path("../generators/agentboard/install/templates/feature_delivery.yml", __dir__)))
          created << ".agentboard/workflows/feature_delivery.yml"
        end
        gitignore = File.join(root, ".gitignore")
        lines = File.exist?(gitignore) ? File.read(gitignore).lines.map(&:strip) : []
        wanted = [ "/.agentboard/worktrees/", "/.agentboard/logs/", "/.agentboard/cache/", "/.agentboard/spool/", "/.agentboard/manifests/", "*.agentboard-backup-*" ]
        missing = wanted - lines
        if missing.any?
          File.open(gitignore, "a") { |f| f.puts("", "# AgentBoard local state", *missing) }
          created << ".gitignore (#{missing.size} entries)"
        end
        providers = Providers.registry.all.reject { |p| p.key == "fake" }.map { |p| pr = p.probe; [ p.key, pr.installed, pr.version ] }
        emit({ git_root: out.strip, created: created, providers: providers.map { |k, i, v| { provider: k, installed: i, version: v } } }, -> {
          puts "AgentBoard initialised in #{root}"
          created.each { |c| puts "  created #{c}" }
          puts "  (nothing to create — already initialised)" if created.empty?
          puts "", "Detected providers:"
          providers.each { |k, i, v| puts "  #{i ? "✓" : "·"} #{k} #{v}" }
          puts "", "Next: bundle exec agentboard provider setup claude · bundle exec agentboard daemon start"
        })
      end
    end

    desc "doctor", "Diagnose the installation"
    def doctor
      guard do
        boot!
        checks = Doctor.new(root: root).checks
        emit(checks.map(&:to_h), -> {
          checks.each { |c| puts "#{{ "ok" => "✓", "warn" => "!", "fail" => "✗" }[c.status]} #{c.name.ljust(26)} #{c.detail}" }
        })
        exit 1 if checks.any? { |c| c.status == "fail" }
      end
    end

    desc "attach KEY", "Associate the active provider session in this directory with a ticket"
    method_option :session, type: :string, desc: "AgentBoard session id or provider session id"
    method_option :provider, type: :string, default: "claude"
    def attach(key)
      guard do
        boot!
        t = ticket!(key)
        session = if options[:session]
          AgentSession.where(project: project).where("id = :s OR external_session_id = :s", s: options[:session]).first
        else
          AgentSession.where(project: project, provider_key: options[:provider], state: "active").where.not(trust_level: "untrusted")
                      .order(Arel.sql("COALESCE(last_seen_at, created_at) DESC")).first
        end
        raise Error.not_found("No active #{options[:provider]} session found; start the agent with hooks configured, or pass --session") unless session

        SessionAssociation.link!(session: session, ticket: t, source: "cli_attach", actor: actor)
        emit({ session_id: session.id, ticket: t.key }, "Attached #{session.display_name} → #{t.key}")
      end
    end

    map "run" => :run_ticket
    desc "run KEY", "Queue a managed execution for a ticket"
    method_option :provider, type: :string, default: "fake"
    method_option :action, type: :string, default: "implement"
    method_option :workflow, type: :string
    method_option :wait, type: :boolean, default: false, desc: "Wait for the execution to finish"
    method_option :scenario, type: :string, desc: "Fake provider scenario"
    def run_ticket(key)
      guard do
        boot!
        t = ticket!(key)
        if options[:workflow]
          WorkflowEngine.sync_from_disk!(project: project)
          r = WorkflowEngine.start!(definition: WorkflowEngine.latest(project: project, name: options[:workflow]), ticket: t, actor: actor)
          emit({ workflow_run_id: r.id }, "Started workflow #{options[:workflow]} (#{r.id})")
          return
        end
        e = Executions.enqueue!(ticket: t, provider_key: options[:provider], action: options[:action], actor: actor,
                                idempotency_key: SecureRandom.uuid, metadata: options[:scenario] ? { "scenario" => options[:scenario] } : {})
        warn "Runtime daemon is not running; the execution stays queued until `agentboard daemon start`." unless Runtime::DaemonControl.status[:running]
        unless options[:wait]
          emit({ execution_id: e.id, status: e.status, attempt: e.attempt }, "Queued #{e.label} (#{e.id})")
          return
        end
        sleep 0.5 until e.reload.terminal?
        emit({ execution_id: e.id, status: e.status, head_sha: e.head_sha, failure_code: e.failure_code }, "#{e.label}: #{e.status}#{" (#{e.failure_code})" if e.failure_code}")
        exit(e.status == "completed" ? 0 : 1)
      end
    end

    desc "verify KEY", "Run the approved verification catalog against the repository HEAD for a ticket"
    def verify(key)
      guard do
        boot!
        results = VerificationService.verify_repository!(ticket: ticket!(key), actor: actor)
        emit(results.map { |r| r.slice(:name, :status, :commit_sha, :exit_code) }, -> {
          results.each { |r| puts "#{r.passed? ? "✓" : "✗"} #{r.name.ljust(14)} #{r.status.ljust(8)} #{r.commit_sha[0, 12]}" }
        })
        exit 1 unless results.select(&:required).all?(&:passed?)
      end
    end

    desc "executions", "List recent executions"
    method_option :limit, type: :numeric, default: 20
    def executions
      guard do
        boot!
        rows = Execution.joins(:ticket).where(agentboard_tickets: { project_id: project.id }).includes(:ticket).recent.limit(options[:limit])
                        .map { |e| { id: e.id, ticket: e.ticket.key, provider: e.provider_key, action: e.action, attempt: e.attempt, status: e.status, head_sha: e.head_sha } }
        emit(rows, -> { table(rows.map { |r| [ r[:id][0, 13], r[:ticket], r[:provider], r[:action], r[:attempt], r[:status] ] }, %w[ID TICKET PROVIDER ACTION ATTEMPT STATUS]) })
      end
    end

    desc "logs EXECUTION_ID", "Print (and optionally follow) the redacted execution log"
    method_option :follow, type: :boolean, aliases: "-f", default: false
    def logs(id)
      guard do
        boot!
        e = find_execution(id)
        offset = 0
        loop do
          if e.log_path && File.exist?(e.log_path)
            File.open(e.log_path, "rb") do |f|
              f.seek(offset)
              chunk = f.read
              offset += chunk.bytesize
              $stdout.write(Redactor.redact(chunk.force_encoding("UTF-8").scrub))
            end
          end
          break unless options[:follow] && !e.reload.terminal?

          sleep 0.5
        end
      end
    end

    desc "cancel EXECUTION_ID", "Cancel an execution (process group gets SIGTERM, then SIGKILL)"
    method_option :reason, type: :string, default: "cancelled from CLI"
    def cancel(id)
      guard do
        boot!
        e = Executions.request_cancel!(execution: find_execution(id), actor: actor, reason: options[:reason])
        emit({ execution_id: e.id, status: e.status }, "Cancellation requested for #{e.label} (#{e.status})")
      end
    end

    desc "resume EXECUTION_ID", "Resume a provider session as a new attempt, if the provider supports it"
    method_option :message, type: :string, default: "Continue the task."
    def resume(id)
      guard do
        boot!
        e = find_execution(id)
        provider = Providers.registry.fetch(e.provider_key)
        raise UnsupportedCapability.new(:session_resume, provider: e.provider_key) unless provider.supports?(:session_resume) && e.metadata["provider_session_id"]

        n = Executions.resume!(execution: e, actor: actor, message: options[:message])
        emit({ execution_id: n.id }, "Queued resume as #{n.label}")
      end
    end

    desc "approvals", "List pending approvals"
    def approvals
      guard do
        boot!
        rows = Approval.pending.where(project: project).order(:created_at).map { |a| { id: a.id, kind: a.action_kind, ticket: a.ticket&.key, head: a.head_sha&.slice(0, 10), by: a.requested_by } }
        emit(rows, -> { table(rows.map(&:values), %w[ID KIND TICKET HEAD REQUESTED_BY]) })
      end
    end

    desc "approve APPROVAL_ID", "Approve (or --reject) a pending approval as the local human"
    method_option :reject, type: :boolean, default: false
    method_option :reason, type: :string
    def approve(id)
      guard do
        boot!
        a = Approvals.decide!(approval: Approval.where(project: project).find(id), actor: actor, decision: options[:reject] ? "rejected" : "approved", reason: options[:reason])
        emit({ id: a.id, decision: a.decision }, "Approval #{a.id[0, 8]}: #{a.decision}")
      end
    end

    desc "cleanup", "Remove eligible worktrees and expired logs (never uncommitted work without --force)"
    method_option :dry_run, type: :boolean, default: false
    method_option :force, type: :boolean, default: false
    def cleanup
      guard do
        boot!
        days = Agentboard.config.settings.dig("retention", "worktree_days").to_i
        manager = Git::WorktreeManager.new(repository: project.repository, workspace: Agentboard.config.workspace_path)
        removed = []
        skipped = []
        Execution.joins(:ticket).where(agentboard_tickets: { project_id: project.id }).terminal.where.not(worktree_path: nil)
                 .where("finished_at < ?", days.days.ago).find_each do |e|
          next unless e.worktree_path.start_with?(Agentboard.config.workspace_path.to_s) && File.directory?(e.worktree_path)
          if e.ticket.status == "review" && !options[:force]
            skipped << [ e.label, "ticket in review" ]
            next
          end
          if options[:dry_run]
            removed << e.label
            next
          end
          manager.remove!(e.worktree_path, force: options[:force])
          removed << e.label
        rescue Agentboard::Error => err
          skipped << [ e.label, err.message ]
        end
        manager.prune! unless options[:dry_run]
        log_days = Agentboard.config.settings.dig("retention", "raw_log_days").to_i
        logs = Dir[File.join(root, ".agentboard", "logs", "*")].select { |d| File.mtime(d) < log_days.days.ago }
        FileUtils.rm_rf(logs) unless options[:dry_run]
        emit({ removed: removed, skipped: skipped, logs_removed: logs.size, dry_run: options[:dry_run] }, -> {
          puts "#{options[:dry_run] ? "Would remove" : "Removed"} #{removed.size} worktree(s), #{logs.size} log dir(s)"
          skipped.each { |l, why| puts "  skipped #{l}: #{why}" }
        })
      end
    end

    desc "export", "Export tickets, events and artifact manifest as JSON (redacted)"
    method_option :output, type: :string, aliases: "-o"
    def export
      guard do
        boot!
        data = {
          exported_at: Time.now.utc.iso8601, agentboard_version: Agentboard::VERSION, project: project.slice(:key, :name, :default_branch),
          tickets: project.tickets.includes(:acceptance_criteria, :comments).map { |t|
            t.slice(:number, :title, :kind, :status, :priority, :labels, :created_at, :completed_at).merge(
              key: t.key, description: Redactor.redact(t.description),
              criteria: t.acceptance_criteria.map { |c| c.slice(:description, :verification_kind, :state) },
              comments: t.comments.map { |c| { author: c.actor_name, body: Redactor.redact(c.body), at: c.created_at } })
          },
          events: Event.where(project_id: project.id).order(:received_at).map { |e| Redactor.redact_value(e.envelope.deep_stringify_keys) },
          artifacts: Artifact.joins(:ticket).where(agentboard_tickets: { project_id: project.id }).map { |a| a.slice(:id, :kind, :uri, :sha256, :commit_sha, :provenance) }
        }
        json = JSON.pretty_generate(data)
        options[:output] ? File.write(options[:output], json) : puts(json)
        warn "Exported #{data[:tickets].size} tickets, #{data[:events].size} events" if options[:output]
      end
    end


    desc "retention", "Apply data retention (old raw logs, provider output events, delivered outbox)"
    method_option :dry_run, type: :boolean, default: false
    def retention
      guard do
        boot!
        report = DataGovernance.apply_retention!(project: project, dry_run: options[:dry_run])
        emit(report, -> { report.each { |k, v| puts "#{k.to_s.ljust(24)} #{v}" } })
      end
    end

    desc "purge", "Permanently delete ALL AgentBoard data of this project (requires --confirm KEY)"
    method_option :confirm, type: :string, required: true, desc: "Type the project key to confirm"
    def purge
      guard do
        boot!
        counts = DataGovernance.purge_project!(project: project, confirm: options[:confirm], actor: actor)
        emit(counts, -> { puts "Purged project data: #{counts.map { |k, v| "#{k}=#{v}" }.join(" ")}" })
      end
    end

    desc "uninstall", "Remove AgentBoard-owned provider config and hooks (never deletes ticket data)"
    def uninstall
      guard do
        boot!
        removed = Providers.registry.all.flat_map do |p|
          manifest = Providers::ConfigEditor.read_manifest(root, p.key)
          manifest ? p.remove_passive_hooks(project: project, root: root, manifest: manifest) : []
        rescue Agentboard::Error
          []
        end
        emit({ removed: removed }, -> {
          puts removed.any? ? "Removed: #{removed.join(", ")}" : "No provider integrations installed"
          puts "Ticket data, events and tables were kept. Drop them with a separate, explicit migration if you really want to."
        })
      end
    end

    private

    def find_execution(id)
      scope = Execution.joins(:ticket).where(agentboard_tickets: { project_id: project.id })
      scope.find_by(id: id) || scope.where("agentboard_executions.id LIKE ?", "#{id}%").first || raise(Error.not_found("Execution #{id} not found"))
    end
  end
end
require "timeout"
require "logger"
require "open3"
require "rbconfig"
require "fileutils"

# Pro commands (support-bundle, audit-export, license) when agentboard-pro is installed.
begin
  require "agentboard/pro"
  require "agentboard/pro/cli"
rescue LoadError
  nil
end
