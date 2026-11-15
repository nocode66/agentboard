module Agentboard
  module Workflows
    # Versioned, validated DAG workflow definitions (spec §9, §28.1).
    class Definition
      SCHEMA_VERSION = 1
      STEP_TYPES = %w[agent command verification human_approval git_commit git_pull_request external condition].freeze
      AGENT_ACTIONS = %w[plan implement review fix_tests summarize].freeze
      RETRYABLE = %w[provider_unavailable transient_io execution_timeout].freeze
      MAX_STEPS = 50
      MAX_ATTEMPTS = 5
      MAX_TIMEOUT = 24 * 3600

      Step = Struct.new(:id, :type, :provider, :action, :command, :depends_on, :condition, :retry, :timeout_seconds,
                        :required_role, :config, :integration, keyword_init: true) do
        def to_h = super.compact.transform_keys(&:to_s)
        def max_attempts = (retry_policy["max_attempts"] || 1).to_i
        def retry_policy = (self.retry || {})
        def retry_on = Array(retry_policy["retry_on"])

        def backoff_for(attempt)
          list = Array(retry_policy["backoff_seconds"])
          (list[attempt - 1] || list.last || 0).to_i
        end
      end

      attr_reader :name, :version, :steps, :timeout_seconds, :raw

      ADVANCED_STEP_TYPES = %w[external git_pull_request].freeze

      def self.parse_yaml(text, catalog: Agentboard.config.verification_catalog, providers: Providers.registry.keys, enforce_features: false)
        data = YAML.safe_load(text.to_s, permitted_classes: [], aliases: false)
        definition = from_h(data, catalog: catalog, providers: providers)
        if enforce_features && definition.advanced_features.any? && !Agentboard.feature?(:advanced_workflows)
          raise Error.policy_denied("This workflow uses #{definition.advanced_features.join(", ")}, which require AgentBoard Pro " \
                                    "(advanced workflows). Sequential agent/command/approval steps are free.",
                                    errors: [ "requires AgentBoard Pro: #{definition.advanced_features.join(", ")}" ])
        end
        definition
      rescue Psych::Exception => e
        raise Error.validation_failed("Invalid workflow YAML: #{e.message[0, 200]}")
      end

      def self.from_h(data, catalog: Agentboard.config.verification_catalog, providers: Providers.registry.keys)
        new(data, catalog: catalog, providers: providers)
      end

      def initialize(data, catalog:, providers:)
        @catalog = catalog
        @providers = providers.map(&:to_s)
        @errors = []
        @raw = data
        validate_top!(data)
        raise Error.validation_failed("Invalid workflow: #{@errors.join("; ")}", errors: @errors) if @errors.any?
      end

      def to_h
        { "version" => version, "name" => name, "timeout_seconds" => timeout_seconds, "steps" => steps.map(&:to_h) }.compact
      end

      def digest = Ids.canonical_digest(to_h)

      # Constructs that need AgentBoard Pro (advanced workflows).
      def advanced_features
        used = []
        used << "conditions" if steps.any?(&:condition)
        used << "retries" if steps.any? { |s| s.max_attempts > 1 }
        used << "per-step timeouts" if steps.any?(&:timeout_seconds)
        (steps.map(&:type) & ADVANCED_STEP_TYPES).each { |t| used << "#{t} steps" }
        used
      end
      def step(id) = steps.find { |s| s.id == id }
      def roots = steps.select { |s| s.depends_on.empty? }

      def topological_order
        indeg = steps.to_h { |s| [ s.id, s.depends_on.size ] }
        queue = steps.select { |s| s.depends_on.empty? }.map(&:id)
        order = []
        until queue.empty?
          id = queue.shift
          order << id
          steps.each do |s|
            next unless s.depends_on.include?(id)

            indeg[s.id] -= 1
            queue << s.id if indeg[s.id].zero?
          end
        end
        order
      end

      private

      def validate_top!(data)
        unless data.is_a?(Hash)
          @errors << "definition must be a mapping"
          return
        end
        data = data.transform_keys(&:to_s)
        unknown = data.keys - %w[version name steps timeout_seconds description]
        @errors << "unknown top-level keys: #{unknown.join(", ")}" if unknown.any?
        @version = data["version"]
        @errors << "version must be #{SCHEMA_VERSION}" unless @version == SCHEMA_VERSION
        @name = data["name"].to_s
        @errors << "name must match /\\A[a-z][a-z0-9_]{0,63}\\z/" unless @name.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
        @timeout_seconds = data["timeout_seconds"]&.to_i
        @errors << "timeout_seconds out of range" if @timeout_seconds && !@timeout_seconds.between?(1, 7 * 24 * 3600)

        raw_steps = data["steps"]
        unless raw_steps.is_a?(Array) && raw_steps.any?
          @errors << "steps must be a non-empty list"
          @steps = []
          return
        end
        @errors << "too many steps (max #{MAX_STEPS})" if raw_steps.size > MAX_STEPS
        @steps = raw_steps.each_with_index.filter_map { |s, i| build_step(s, i) }
        ids = @steps.map(&:id)
        dupes = ids.tally.select { |_, c| c > 1 }.keys
        @errors << "duplicate step ids: #{dupes.join(", ")}" if dupes.any?
        @steps.each do |s|
          (s.depends_on - ids).each { |d| @errors << "step #{s.id} depends on unknown step #{d}" }
          @errors << "step #{s.id} depends on itself" if s.depends_on.include?(s.id)
          next unless s.condition

          refs = Condition.parse(s.condition).step_refs
          (refs - ids).each { |r| @errors << "step #{s.id} condition references unknown step #{r}" }
          (refs - ancestors(s.id)).each { |r| @errors << "step #{s.id} condition references #{r}, which is not an ancestor" } if @errors.empty?
        rescue Condition::SyntaxError => e
          @errors << "step #{s.id} condition: #{e.message}"
        end
        @errors << "workflow contains a dependency cycle" if @errors.empty? && topological_order.size != @steps.size
      end

      def ancestors(id, seen = Set.new)
        step = @steps.find { |s| s.id == id }
        return seen unless step

        step.depends_on.each { |d| ancestors(d, seen << d) unless seen.include?(d) }
        seen.to_a
      end

      def build_step(raw, index)
        unless raw.is_a?(Hash)
          @errors << "step ##{index + 1} must be a mapping"
          return nil
        end
        raw = raw.transform_keys(&:to_s)
        allowed = %w[id type provider action command depends_on condition retry timeout_seconds required_role config integration]
        unknown = raw.keys - allowed
        @errors << "step #{raw["id"] || index + 1}: unknown keys #{unknown.join(", ")}" if unknown.any?

        id = raw["id"].to_s
        @errors << "step ##{index + 1}: id must match /\\A[a-z][a-z0-9_]{0,63}\\z/" unless id.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
        type = raw["type"].to_s
        @errors << "step #{id}: unknown type #{type}" unless STEP_TYPES.include?(type)

        case type
        when "agent"
          @errors << "step #{id}: unknown provider #{raw["provider"]}" unless @providers.include?(raw["provider"].to_s)
          @errors << "step #{id}: action must be one of #{AGENT_ACTIONS.join(", ")}" unless AGENT_ACTIONS.include?(raw["action"].to_s)
        when "command", "verification"
          if raw["command"].is_a?(Array) || raw["command"].to_s.include?(" ")
            @errors << "step #{id}: command must reference a catalog entry by name, not a shell string"
          elsif !@catalog.names.include?(raw["command"].to_s)
            @errors << "step #{id}: command #{raw["command"]} is not in the approved catalog"
          end
        when "external"
          name = raw["integration"].to_s
          unless (Agentboard.config.settings["integrations"] || {}).key?(name)
            @errors << "step #{id}: integration #{name.inspect} is not configured under `integrations`"
          end
          if retry_policy = raw["retry"]
            @errors << "step #{id}: external steps cannot be retried automatically" if retry_policy.is_a?(Hash) && retry_policy["max_attempts"].to_i > 1
          end
        when "human_approval"
          role = (raw["required_role"] || "maintainer").to_s
          @errors << "step #{id}: required_role must be maintainer or administrator" unless %w[maintainer administrator].include?(role)
        end

        retry_policy = raw["retry"]
        if retry_policy
          if retry_policy.is_a?(Hash)
            retry_policy = retry_policy.transform_keys(&:to_s)
            attempts = retry_policy["max_attempts"].to_i
            @errors << "step #{id}: retry.max_attempts must be 1..#{MAX_ATTEMPTS}" unless attempts.between?(1, MAX_ATTEMPTS)
            backoff = Array(retry_policy["backoff_seconds"])
            @errors << "step #{id}: retry.backoff_seconds must be integers 0..3600" unless backoff.all? { |b| b.is_a?(Integer) && b.between?(0, 3600) }
            bad = Array(retry_policy["retry_on"]).map(&:to_s) - RETRYABLE
            @errors << "step #{id}: retry_on contains unsupported reasons #{bad.join(", ")}" if bad.any?
            if %w[git_commit git_pull_request command].include?(type) && attempts > 1
              @errors << "step #{id}: non-idempotent #{type} steps cannot be retried automatically"
            end
          else
            @errors << "step #{id}: retry must be a mapping"
          end
        end

        timeout = raw["timeout_seconds"]&.to_i
        @errors << "step #{id}: timeout_seconds must be 1..#{MAX_TIMEOUT}" if timeout && !timeout.between?(1, MAX_TIMEOUT)
        depends = Array(raw["depends_on"]).map(&:to_s)

        Step.new(id: id, type: type, provider: raw["provider"]&.to_s, action: raw["action"]&.to_s, command: raw["command"]&.to_s,
                 depends_on: depends, condition: raw["condition"]&.to_s, retry: retry_policy.is_a?(Hash) ? retry_policy : nil,
                 timeout_seconds: timeout, required_role: raw["required_role"]&.to_s, config: raw["config"].is_a?(Hash) ? raw["config"] : nil,
                 integration: raw["integration"]&.to_s)
      end
    end
  end
end
