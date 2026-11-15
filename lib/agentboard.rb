require "securerandom"
require "digest"
require "json"
require "yaml"
require "pathname"
require "set"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string"

require "agentboard/version"
require "agentboard/errors"
require "agentboard/result"
require "agentboard/ids"
require "agentboard/redactor"
require "agentboard/extensions"
require "agentboard/command_policy"
require "agentboard/process_ancestry"
require "agentboard/json_log_formatter"
require "agentboard/container_sandbox"
require "agentboard/agent_container"
require "agentboard/egress_proxy"
require "agentboard/event_schema"
require "agentboard/configuration"
require "agentboard/state_machines"
require "agentboard/authorization"
require "agentboard/providers"
require "agentboard/git"
require "agentboard/verification"
require "agentboard/workflows"
require "agentboard/rails_introspection"
require "agentboard/context_builder"
require "agentboard/capture"
require "agentboard/runtime"
require "agentboard/engine" if defined?(Rails::Engine)

# AgentBoard: local-first, AI-native development management and orchestration.
#
# The Rails Engine (UI, API, persistence) and the runtime daemon (agent processes)
# are separate OS processes. Everything under lib/ is framework-independent unless
# it explicitly requires Active Record models from app/.
module Agentboard
  class << self
    def configuration
      @configuration ||= Configuration.new
    end
    alias_method :config, :configuration

    def configure
      yield configuration
    end

    def reset_configuration!
      @configuration = nil
    end

    # Third-party adapter registration (spec §5):
    #   Agentboard.register_provider(:custom_agent, adapter: MyCustomAgentAdapter)
    def register_provider(key, adapter:)
      Providers.registry.register(key, adapter)
    end

    def logger
      @logger ||= if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger
      else
        require "logger"
        Logger.new($stderr, level: Logger::INFO)
      end
    end
    attr_writer :logger
  end
end
