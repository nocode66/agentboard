module Agentboard
  # Open-core extension points (spec §16). The MIT core works fully offline for a single
  # local user. Commercial extensions (agentboard-pro) register here and unlock features
  # according to their own licence; the core never phones home or needs an account.
  module Extensions
    FEATURES = {
      team_mode: "Team mode: host-app authentication, roles and separation of duties",
      advanced_workflows: "Advanced workflows: conditions, retries, per-step timeouts, external and pull-request steps",
      governance: "Analytics & governance: operational metrics, support bundle, scheduled retention, audit export",
      capture: "Capture widget beyond development (team use on staging) and region screenshots",
      git_hosting: "Git hosting integrations (GitHub, GitLab, Bitbucket): signed webhooks, merge-aware completion, pull-request creation"
    }.freeze

    Extension = Struct.new(:name, :version, :features, :status, keyword_init: true) do
      def enabled_features = Array(features.respond_to?(:call) ? features.call : features).map(&:to_sym)
      def status_info = status.respond_to?(:call) ? status.call : status
    end

    @extensions = {}
    @hooks = Hash.new { |h, k| h[k] = [] }
    @step_handlers = {}

    class << self
      attr_reader :extensions, :step_handlers

      def register(name, version:, features:, status: nil)
        @extensions[name.to_s] = Extension.new(name: name.to_s, version: version, features: features, status: status)
      end

      def unregister(name) = @extensions.delete(name.to_s)

      def feature?(key) = @extensions.values.any? { |e| e.enabled_features.include?(key.to_sym) }

      def require!(key)
        return true if feature?(key)

        raise Error.policy_denied("#{FEATURES.fetch(key.to_sym)} requires AgentBoard Pro with a valid licence", feature: key.to_s)
      end

      # Hooks: on(:event) { |*args| … }; run(:event, *args) calls every subscriber.
      def on(event, &block) = (@hooks[event.to_sym] << block)
      def run(event, *args, **kwargs) = @hooks[event.to_sym].map { |h| h.call(*args, **kwargs) }
      def hooks?(event) = @hooks[event.to_sym].any?

      # Workflow step types provided by extensions.
      def register_step_handler(type, &block) = (@step_handlers[type.to_s] = block)
      def step_handler(type) = @step_handlers[type.to_s]

      def reset_hooks!
        @hooks.clear
        @step_handlers.clear
      end
    end
  end

  def self.feature?(key) = Extensions.feature?(key)
  def self.require_feature!(key) = Extensions.require!(key)
end
