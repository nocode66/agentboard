module Agentboard
  module Providers
    CAPABILITIES = %i[mcp passive_hooks active_execution structured_events streaming cancellation session_resume permission_requests].freeze

    # Typed results (spec §26.1). Handles never carry provider secrets.
    ProbeResult = Struct.new(:provider, :installed, :version, :authenticated, :supported_capabilities, :validation, :diagnostics, keyword_init: true) do
      def supports?(cap) = Array(supported_capabilities).include?(cap.to_sym)

      def to_h
        { provider: provider, installed: installed, version: version, authenticated: authenticated,
          supported_capabilities: Array(supported_capabilities).map(&:to_s), validation: validation, diagnostics: diagnostics }
      end
    end

    # What the supervisor needs to spawn a provider process safely.
    # mounts: extra host paths mounted read-only when the agent runs in a container.
    # credential_aliases: { "NAME_IN_CONTAINER" => "HOST_VARIABLE" } — forwarded by name only.
    LaunchSpec = Struct.new(:argv, :env, :stdin_data, :chdir, :passthrough_env, :mounts, :credential_aliases, keyword_init: true)

    # Normalized event produced by `parse_event`.
    NormalizedEvent = Struct.new(:type, :payload, :external_session_id, :usage, :terminal, :status, :provenance, keyword_init: true) do
      def self.build(type, payload = {}, **opts)
        new(type: type, payload: payload, provenance: "provider_reported", terminal: false, **opts)
      end
    end

    Usage = Struct.new(:input_tokens, :output_tokens, :reported_cost, :currency, :metering_kind, keyword_init: true)

    # Passive setup outcome: exact changes for display and the reversal manifest.
    SetupResult = Struct.new(:provider, :changes, :manifest, :backups, :warnings, keyword_init: true)
  end
end
