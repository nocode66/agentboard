module Agentboard
  # Base error carrying a stable, client-facing code (spec §24.3).
  # Messages must never include secrets or stack traces.
  class Error < StandardError
    CODES = %w[
      NOT_FOUND UNAUTHORIZED FORBIDDEN VALIDATION_FAILED VERSION_CONFLICT LEASE_CONFLICT
      LEASE_EXPIRED INVALID_TRANSITION CAPABILITY_UNAVAILABLE PROVIDER_UNAVAILABLE
      APPROVAL_REQUIRED POLICY_DENIED EXECUTION_TIMEOUT WORKSPACE_CONFLICT RATE_LIMITED
      INTERNAL_ERROR
    ].freeze

    RETRYABLE = %w[LEASE_CONFLICT VERSION_CONFLICT PROVIDER_UNAVAILABLE RATE_LIMITED EXECUTION_TIMEOUT].freeze

    attr_reader :code, :details

    def initialize(code, message = nil, details: {})
      raise ArgumentError, "unknown error code #{code}" unless CODES.include?(code)

      @code = code
      @details = details
      super(message || code.downcase.tr("_", " "))
    end

    def retryable? = RETRYABLE.include?(code)

    def to_h
      { code: code, message: message, retryable: retryable?, details: details }
    end

    CODES.each do |c|
      define_singleton_method(c.downcase) { |message = nil, **details| new(c, message, details: details) }
    end
  end

  # Raised by provider adapters for features a provider/version does not support.
  class UnsupportedCapability < Error
    def initialize(capability, provider: nil)
      super("CAPABILITY_UNAVAILABLE", "#{provider || "provider"} does not support #{capability}",
            details: { capability: capability.to_s, provider: provider&.to_s }.compact)
    end
  end
end
