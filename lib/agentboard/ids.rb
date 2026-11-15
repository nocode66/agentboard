module Agentboard
  # Application-generated identifiers. UUIDv7 is time-ordered, portable across
  # PostgreSQL and SQLite, and safe to generate outside the database (spec §23.1).
  module Ids
    module_function

    def uuid = SecureRandom.uuid_v7
    def correlation = "c-#{SecureRandom.hex(8)}"
    def token(bytes = 32) = SecureRandom.urlsafe_base64(bytes)
    def digest(value) = Digest::SHA256.hexdigest(value.to_s)

    # Constant-time comparison of a presented secret with a stored digest.
    def secure_match?(presented, stored_digest)
      return false if presented.nil? || stored_digest.nil?

      a = digest(presented)
      a.bytesize == stored_digest.bytesize && OpenSSL.fixed_length_secure_compare(a, stored_digest)
    end

    # Canonical JSON (sorted keys) for digests of definitions and approval actions.
    def canonical_json(value)
      case value
      when Hash then "{" + value.map { |k, v| [ k.to_s, v ] }.sort_by(&:first).map { |k, v| "#{k.to_json}:#{canonical_json(v)}" }.join(",") + "}"
      when Array then "[" + value.map { |v| canonical_json(v) }.join(",") + "]"
      when Symbol then value.to_s.to_json
      else value.to_json
      end
    end

    def canonical_digest(value) = digest(canonical_json(value))
  end
end
require "openssl"
