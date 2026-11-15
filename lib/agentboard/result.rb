module Agentboard
  # Command result envelope (spec §24.3):
  #   { ok: true,  data: {...}, correlation_id: "c-123" }
  #   { ok: false, error: { code:, message:, retryable:, details: }, correlation_id: "c-123" }
  class Result
    attr_reader :data, :error, :correlation_id

    def self.success(data = {}, correlation_id: Ids.correlation) = new(data: data, correlation_id: correlation_id)
    def self.failure(error, correlation_id: Ids.correlation) = new(error: error, correlation_id: correlation_id)

    # Runs the block, converting Agentboard::Error into a failure envelope and any other
    # exception into an opaque INTERNAL_ERROR (never leaking the original message).
    def self.capture(correlation_id: Ids.correlation)
      success(yield, correlation_id: correlation_id)
    rescue Agentboard::Error => e
      failure(e, correlation_id: correlation_id)
    rescue ActiveRecord::StaleObjectError => e
      failure(Error.version_conflict("Record was modified concurrently; reload and retry"), correlation_id: correlation_id)
    rescue ActiveRecord::RecordNotFound
      failure(Error.not_found("Record not found"), correlation_id: correlation_id)
    rescue ActiveRecord::RecordInvalid => e
      failure(Error.validation_failed(e.record.errors.full_messages.to_sentence), correlation_id: correlation_id)
    rescue StandardError => e
      Agentboard.logger.error("[agentboard] #{correlation_id} #{e.class}: #{Redactor.redact(e.message)}")
      failure(Error.internal_error("Internal error (correlation #{correlation_id})"), correlation_id: correlation_id)
    end

    def initialize(data: nil, error: nil, correlation_id:)
      @data = data
      @error = error
      @correlation_id = correlation_id
    end

    def ok? = error.nil?

    def to_h
      if ok?
        { ok: true, data: data, correlation_id: correlation_id }
      else
        { ok: false, error: error.to_h, correlation_id: correlation_id }
      end
    end

    def to_json(*args) = to_h.to_json(*args)
  end
end
