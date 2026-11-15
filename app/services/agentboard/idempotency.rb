module Agentboard
  # Stores the response of a mutating request keyed by (scope, key). A replay with the same
  # request digest returns the stored response; a different payload under the same key is
  # rejected (VALIDATION_FAILED) to prevent accidental key reuse.
  module Idempotency
    TTL = 24.hours

    module_function

    def call(scope:, key:, request:)
      return yield if key.blank?

      digest = Ids.canonical_digest(request)
      if (existing = IdempotencyKey.where(scope: scope, key: key).where("expires_at > ?", Time.current).first)
        raise Error.validation_failed("Idempotency key reused with a different request") if existing.request_digest != digest

        return existing.response
      end

      response = yield
      IdempotencyKey.where(scope: scope, key: key).where("expires_at <= ?", Time.current).delete_all
      IdempotencyKey.create!(scope: scope, key: key, request_digest: digest, response: response, expires_at: Time.current + TTL)
      response
    rescue ActiveRecord::RecordNotUnique
      IdempotencyKey.find_by!(scope: scope, key: key).response
    end
  end
end
