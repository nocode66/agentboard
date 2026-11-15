module Agentboard
  # Classifies agent tool requests before a human is asked (spec §14, §30.3).
  #   :deny  – never allowed by an agent (production deploys, credential access, history rewrites)
  #   :ask   – needs explicit human approval
  # Inputs are untrusted; matching is conservative and errs towards asking/denying.
  module CommandPolicy
    PRODUCTION = [
      /\b(kamal|cap|capistrano|mina)\b.*\bdeploy\b/i, /\bdeploy\b.*\b(prod|production)\b/i,
      /\bRAILS_ENV=production\b/i, /\bheroku\b.*\b(run|releases|config:set|ps:scale)\b/i,
      /\bkubectl\b.*\b(apply|delete|rollout|scale)\b/i, /\bterraform\b.*\b(apply|destroy)\b/i,
      /\bfly(ctl)?\b.*\bdeploy\b/i, /\bgh\b.*\brelease\b.*\bcreate\b/i
    ].freeze
    DESTRUCTIVE = [
      /\bgit\b.*\bpush\b.*(--force|-f\b|--mirror|\+)/i, /\bgit\b.*\bpush\b.*\b(main|master|production|release)\b/i,
      /\brm\s+-[a-z]*r[a-z]*f?[a-z]*\s+(\/|~|\$HOME)(\s|$)/i, /\bdb:(drop|reset|schema:load|purge)\b/i,
      /\bmkfs\b|\bdd\s+if=/i, /\bchmod\s+-R\s+777\s+\//i
    ].freeze
    CREDENTIALS = [
      /\b(printenv|env)\s*$/i, /\bcat\b.*(\.env\b|credentials|\.pem\b|id_rsa|\.netrc|\.aws\/)/i,
      /\bsecurity\s+find-(generic|internet)-password\b/i, /\bkeychain\b/i, /rails\s+credentials:show/i
    ].freeze

    Decision = Struct.new(:verdict, :reason, :action_kind, keyword_init: true)

    module_function

    def classify(tool_name, input)
      text = summarize(tool_name, input)
      if !Agentboard.config.security["allow_production_commands"] && PRODUCTION.any? { |re| re.match?(text) }
        return Decision.new(verdict: :deny, reason: "production operations are not allowed for agents", action_kind: "production_deploy")
      end
      return Decision.new(verdict: :deny, reason: "destructive or protected-branch operation", action_kind: "protected_branch_merge") if DESTRUCTIVE.any? { |re| re.match?(text) }
      return Decision.new(verdict: :deny, reason: "credential access is not allowed for agents", action_kind: "credential_access") if CREDENTIALS.any? { |re| re.match?(text) }

      Decision.new(verdict: :ask, reason: "requires human approval", action_kind: "privileged_shell")
    end

    def summarize(tool_name, input)
      input = input.is_a?(Hash) ? input : {}
      detail = input["command"] || input["file_path"] || input["path"] || input["url"] || input.to_json
      "#{tool_name} #{detail}"[0, 2000]
    end
  end
end
