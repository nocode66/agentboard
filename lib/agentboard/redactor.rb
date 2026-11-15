module Agentboard
  # Redacts secrets from logs, hook payloads, event fields and exports (spec §14, AT-13).
  # Patterns are intentionally conservative; projects can add their own via configuration.
  module Redactor
    MASK = "[REDACTED]".freeze

    DEFAULT_PATTERNS = [
      /\bsk-ant-[A-Za-z0-9_\-]{16,}/,                        # Anthropic
      /\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,}/,                  # OpenAI
      /\bgh[pousr]_[A-Za-z0-9]{30,}/,                        # GitHub tokens
      /\bgithub_pat_[A-Za-z0-9_]{30,}/,
      /\bxox[abposr]-[A-Za-z0-9\-]{10,}/,                    # Slack
      /\bAKIA[0-9A-Z]{16}\b/,                                # AWS access key id
      /\bAIza[0-9A-Za-z_\-]{35}\b/,                          # Google API key
      /\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}/, # JWT
      /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/,
      /(?<=:\/\/)[^\/\s:@]+:[^\/\s@]+(?=@)/                 # credentials in URLs
    ].freeze

    # key=value / "key": "value" assignments for sensitive-looking keys
    ASSIGNMENT = /((?:api[_-]?key|secret|token|password|passwd|authorization|bearer|private[_-]?key|access[_-]?key|lease_token)["']?\s*[:=]\s*["']?)([^\s"',;}]{6,})/i

    SENSITIVE_KEYS = /\A(?:.*(?:password|passwd|secret|token|api[_-]?key|authorization|cookie|credential|private[_-]?key).*)\z/i

    module_function

    def patterns
      DEFAULT_PATTERNS + Array(Agentboard.config.redaction_patterns)
    end

    # Returns [redacted_string, count_of_redactions]
    def redact_with_count(text)
      return [ text, 0 ] unless text.is_a?(String)

      count = 0
      out = text.dup
      patterns.each do |re|
        out = out.gsub(re) { count += 1; MASK }
      end
      out = out.gsub(ASSIGNMENT) { count += 1; "#{$1}#{MASK}" }
      [ out, count ]
    end

    def redact(text) = redact_with_count(text).first

    def secret?(text) = redact_with_count(text).last.positive?

    # Deep redaction of hashes/arrays: sensitive keys are masked entirely,
    # strings are pattern-scanned.
    def redact_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(k, v), h|
          h[k] = (k.to_s.match?(SENSITIVE_KEYS) && !v.is_a?(Hash) && !v.is_a?(Array) && !v.nil?) ? MASK : redact_value(v)
        end
      when Array then value.map { |v| redact_value(v) }
      when String then redact(value)
      else value
      end
    end
  end
end
