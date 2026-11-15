module Agentboard
  # Desired behaviour of an AgentBoard installation. Values come from (lowest to highest
  # precedence) built-in defaults, config/agentboard.yml, .agentboard/config.yml and the
  # Ruby initializer. Actual provider capabilities are always *detected* at runtime;
  # configuration only expresses intent (spec §3).
  class Configuration
    DEFAULTS = {
      "project" => { "name" => nil, "key" => nil },
      "runtime" => {
        "mode" => "local",
        "max_concurrent_executions" => 1,
        "workspace" => ".agentboard/worktrees",
        "poll_interval" => 0.5,
        "cancel_grace_seconds" => 5,
        "permission_timeout_seconds" => 600,
        "execution_timeout_seconds" => 3600,
        "max_log_bytes" => 5 * 1024 * 1024,
        "socket_dir" => nil
      },
      "providers" => {
        "claude" => { "enabled" => true, "passive" => true, "active" => true },
        "codex" => { "enabled" => true, "passive" => true, "active" => true },
        "cursor" => { "enabled" => false, "passive" => true, "active" => false },
        "fake" => { "enabled" => true, "passive" => true, "active" => true }
      },
      "security" => {
        "require_review" => true,
        "allow_production_commands" => false,
        "sandbox" => "none",
        "trusted_local_execution" => false
      },
      "completion" => {
        "require_criteria_verified" => true,
        "require_checks" => true,
        "require_approval" => true,
        "require_merged_pr" => "when_linked"
      },
      "verification_commands" => {
        "rails_test" => { "argv" => %w[bin/rails test], "timeout_seconds" => 900, "required" => true },
        "rubocop" => { "argv" => %w[bin/rubocop], "timeout_seconds" => 600, "required" => false }
      },
      "leases" => { "default_seconds" => 900, "min_seconds" => 30, "max_seconds" => 3600 },
      "retention" => { "raw_log_days" => 30, "worktree_days" => 7, "provider_output_event_days" => 30 },
      "github" => { "webhook_secret_env" => "AGENTBOARD_GITHUB_WEBHOOK_SECRET", "repository" => nil },
      "git_hosts" => { "default" => nil },
      "telemetry" => { "enabled" => false },
      "board" => { "columns" => %w[backlog ready claimed in_progress testing review done], "done_visible_days" => 14 }
    }.freeze

    attr_accessor :root, :authenticate_with, :current_actor_with, :redaction_patterns,
                  :allow_non_local_requests, :dashboard_token, :mount_in_production
    attr_reader :settings

    def initialize
      @settings = deep_dup(DEFAULTS)
      @root = nil
      @authenticate_with = nil
      @current_actor_with = nil
      @redaction_patterns = []
      @allow_non_local_requests = false
      @dashboard_token = ENV["AGENTBOARD_DASHBOARD_TOKEN"]
      @loaded_files = []
    end

    def root_path
      Pathname.new(root || (defined?(Rails) && Rails.respond_to?(:root) && Rails.root) || Dir.pwd).expand_path
    end

    def config_files
      [ root_path.join("config/agentboard.yml"), root_path.join(".agentboard/config.yml") ]
    end

    # Loads YAML config files with safe loading (no aliases, no arbitrary objects).
    def load!
      config_files.each do |path|
        next unless path.file?

        data = YAML.safe_load(path.read, permitted_classes: [], aliases: false) || {}
        raise Error.validation_failed("#{path} must contain a mapping") unless data.is_a?(Hash)

        deep_merge!(@settings, data)
        @loaded_files << path.to_s
      end
      self
    end

    attr_reader :loaded_files

    def [](key) = settings[key.to_s]
    def dig(*keys) = settings.dig(*keys.map(&:to_s))

    def update(hash)
      deep_merge!(@settings, stringify(hash))
      self
    end

    def runtime = settings["runtime"]
    def security = settings["security"]
    def completion = settings["completion"]
    def leases = settings["leases"]

    def max_concurrent_executions = runtime["max_concurrent_executions"].to_i.clamp(1, 64)

    def workspace_path
      path = Pathname.new(runtime["workspace"])
      path.absolute? ? path : root_path.join(path)
    end

    def runtime_dir
      # macOS limits Unix socket paths to 104 bytes and $TMPDIR (/var/folders/…) is long,
      # so fall back to /tmp when the socket path would not fit. The directory is 0700.
      dir = runtime["socket_dir"] || File.join(Dir.tmpdir, "agentboard-#{Process.uid}")
      dir = File.join("/tmp", "agentboard-#{Process.uid}") if !runtime["socket_dir"] && File.join(dir, "x" * 18).bytesize > 100
      Pathname.new(dir)
    end

    def provider_settings(key) = settings.dig("providers", key.to_s) || {}
    def provider_enabled?(key) = provider_settings(key)["enabled"] != false

    # Visible Kanban columns (validated, in canonical order). Hidden states fold into the
    # nearest visible earlier column so no ticket disappears from the board.
    def board_columns
      wanted = Array(settings.dig("board", "columns")).map(&:to_s) & StateMachines::Ticket::BOARD_COLUMNS
      wanted = StateMachines::Ticket::BOARD_COLUMNS if wanted.empty?
      StateMachines::Ticket::BOARD_COLUMNS & wanted
    end

    def board_column_for(status)
      cols = board_columns
      status = { "blocked" => "ready", "reopened" => "ready" }.fetch(status.to_s, status.to_s)
      return status if cols.include?(status)

      order = StateMachines::Ticket::BOARD_COLUMNS
      idx = order.index(status) || 0
      order[0..idx].reverse.find { |c| cols.include?(c) } || cols.first
    end

    def verification_catalog
      Verification::Catalog.new(settings["verification_commands"] || {})
    end

    private

    def deep_merge!(target, source)
      source.each do |k, v|
        k = k.to_s
        if v.is_a?(Hash) && target[k].is_a?(Hash)
          deep_merge!(target[k], v)
        else
          target[k] = v.is_a?(Hash) ? stringify(v) : v
        end
      end
      target
    end

    def stringify(h) = h.to_h { |k, v| [ k.to_s, v.is_a?(Hash) ? stringify(v) : v ] }
    def deep_dup(obj) = Marshal.load(Marshal.dump(obj))
  end
end
require "tmpdir"
