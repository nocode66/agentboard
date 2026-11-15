require "rbconfig"

module Agentboard
  module Providers
    # Deterministic provider for tests and demos (spec §35.3.4). It launches a small Ruby
    # script that emits JSONL events and edits files in the worktree. Never calls a paid API.
    #
    # Scenarios (profile config `scenario`): success, fail, slow, permission, secret, malformed, noop
    class Fake < Base
      SCRIPT = File.expand_path("fake_agent_script.rb", __dir__)

      def self.key = :fake
      def self.display_name = "Fake agent (testing)"

      def probe(environment: ENV)
        ProbeResult.new(provider: key, installed: true, version: "fake-#{Agentboard::VERSION}", authenticated: true,
                        supported_capabilities: CAPABILITIES - [ :passive_hooks ], validation: "built-in", diagnostics: [])
      end

      def launch_spec(execution:, worktree:, context_path:, prompt:)
        scenario = (execution.agent_profile&.config || {}).fetch("scenario", execution.metadata["scenario"] || "success").to_s
        raise Error.validation_failed("Unknown fake scenario") unless scenario.match?(/\A[a-z_]+\z/)

        container = execution.metadata["isolation"] == "container"
        LaunchSpec.new(argv: [ container ? "ruby" : RbConfig.ruby, SCRIPT, "--scenario", scenario ],
                       env: { "AGENTBOARD_TICKET" => execution.ticket.key }, stdin_data: prompt, chdir: worktree,
                       mounts: container ? [ File.dirname(SCRIPT) ] : nil)
      end

      def resume_spec(execution:, worktree:, input:)
        sid = execution.metadata["provider_session_id"].to_s
        raise UnsupportedCapability.new(:session_resume, provider: key) unless sid.start_with?("fake-")

        LaunchSpec.new(argv: [ RbConfig.ruby, SCRIPT, "--scenario", "resume", "--session", sid ],
                       env: { "AGENTBOARD_TICKET" => execution.ticket.key }, stdin_data: input.to_s, chdir: worktree)
      end

      def parse_event(raw_event:)
        data = safe_json(raw_event)
        return [ NormalizedEvent.build("agent.execution.output", { "text" => raw_event.to_s.chomp[0, 4000] }) ] unless data.is_a?(Hash)

        case data["type"]
        when "session" then [ NormalizedEvent.build("agent.session.started", data.slice("model"), external_session_id: data["session_id"]) ]
        when "message" then [ NormalizedEvent.build("agent.execution.message", { "text" => data["text"].to_s[0, 8000] }) ]
        when "tool_start" then [ NormalizedEvent.build("agent.tool.started", data.slice("tool", "target")) ]
        when "tool_end" then [ NormalizedEvent.build("agent.tool.completed", data.slice("tool", "target", "ok")) ]
        when "permission" then [ NormalizedEvent.build("agent.execution.permission_requested", data.slice("tool", "reason"), status: "waiting_for_permission") ]
        when "usage"
          [ NormalizedEvent.build("agent.execution.usage", data.slice("input_tokens", "output_tokens"),
                                  usage: Usage.new(input_tokens: data["input_tokens"], output_tokens: data["output_tokens"], metering_kind: "unknown")) ]
        when "result"
          [ NormalizedEvent.build("agent.execution.result", data.slice("ok", "summary"), terminal: true, status: data["ok"] ? "succeeded" : "failed") ]
        else
          [ NormalizedEvent.build("agent.provider.unknown", { "raw_type" => data["type"].to_s[0, 64] }) ]
        end
      end
    end
  end
end
