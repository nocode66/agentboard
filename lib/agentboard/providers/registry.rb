module Agentboard
  module Providers
    class Registry
      REQUIRED_METHODS = %i[probe parse_event launch_spec].freeze

      def initialize
        @adapters = {}
      end

      def register(key, adapter)
        key = key.to_s
        raise ArgumentError, "provider key must match /\\A[a-z][a-z0-9_]*\\z/" unless key.match?(/\A[a-z][a-z0-9_]*\z/)
        missing = REQUIRED_METHODS.reject { |m| adapter.method_defined?(m) }
        raise ArgumentError, "#{adapter} must implement #{missing.join(", ")}" if missing.any?

        @adapters[key] = adapter
      end

      def keys = @adapters.keys
      def registered?(key) = @adapters.key?(key.to_s)

      def adapter_class(key)
        @adapters.fetch(key.to_s) { raise Error.not_found("Unknown provider #{key}") }
      end

      def fetch(key, settings: nil) = adapter_class(key).new(settings: settings)
      def each(&) = @adapters.each_key.map { |k| fetch(k) }.each(&)
      def all = @adapters.keys.map { |k| fetch(k) }
    end
  end
end
