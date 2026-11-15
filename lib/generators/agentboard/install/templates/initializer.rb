# AgentBoard is usually bundled in the :development group only, so this file must be a no-op
# in environments (test, production) where the gem is not loaded.
return unless defined?(Agentboard::Engine)

# AgentBoard configuration. YAML in config/agentboard.yml and .agentboard/config.yml is
# loaded first; anything set here takes precedence.
Agentboard.configure do |config|
  # Reuse your app's authentication for the dashboard (return an actor or nil):
  #
  # config.authenticate_with = ->(controller) do
  #   user = controller.send(:current_user) or next nil
  #   Agentboard::Authorization::Actor.new(type: "human", id: user.id.to_s, name: user.email, role: user.admin? ? "administrator" : "developer")
  # end
  #
  # Without an adapter the dashboard only accepts local requests. Optionally require a token:
  # config.dashboard_token = ENV["AGENTBOARD_DASHBOARD_TOKEN"]
  #
  # Extra secret patterns to redact from logs, events and exports:
  # config.redaction_patterns = [/acme_live_[A-Za-z0-9]{24}/]
end

# Third-party provider adapters:
# Agentboard.register_provider(:custom_agent, adapter: MyCustomAgentAdapter)
