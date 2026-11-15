module Agentboard
  # Versioned event payloads (spec §11, §23.4). Historical events are never rewritten:
  # readers call `EventSchema.upcast` to see old payloads in the current shape.
  #
  #   EventSchema.register("agent.execution.usage", from: 1) { |p| … returns v2 payload … }
  module EventSchema
    @current = Hash.new(1)
    @upcasters = {}

    class << self
      def current_version(type) = @current[type.to_s]

      def register(type, from:, &block)
        @upcasters[[ type.to_s, from ]] = block
        @current[type.to_s] = [ @current[type.to_s], from + 1 ].max
      end

      # Applies successive upcasters from `version` to the current version.
      def upcast(type, version, payload)
        version = version.to_i
        data = payload.is_a?(Hash) ? payload.dup : {}
        while version < current_version(type)
          step = @upcasters[[ type.to_s, version ]] or break
          data = step.call(data)
          version += 1
        end
        data
      end
    end

    # v2 (AgentBoard 0.2): monetary amounts carry an explicit currency; unknown stays nil.
    register("agent.execution.usage", from: 1) do |p|
      usd = p.delete("reported_cost_usd")
      p.merge("reported_cost" => usd, "currency" => usd.nil? ? nil : "USD")
    end
  end
end
