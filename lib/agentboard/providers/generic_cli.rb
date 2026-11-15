module Agentboard
  module Providers
    # Placeholder adapters for P2 providers (Gemini CLI, OpenCode, Copilot). They detect the
    # binary and report MCP-only capability; active execution is unavailable until a
    # fixture-backed adapter is written. This keeps the UI honest about support levels.
    class GenericCli < Base
      class << self
        attr_reader :provider_key, :binary_name, :display

        def for(key:, binary:, display:)
          Class.new(self) do
            @provider_key = key
            @binary_name = binary
            @display = display
          end
        end

        def key = provider_key.to_sym
        def display_name = display
        def binary = binary_name
      end

      def probe(environment: ENV)
        bin = which(self.class.binary)
        version = bin && run_version([ bin, "--version" ]).to_s[/\d+\.\d+(?:\.\d+)?/]
        ProbeResult.new(provider: key, installed: !bin.nil?, version: version, authenticated: nil,
                        supported_capabilities: bin ? %i[mcp] : [], validation: bin ? "detected (P2, MCP only)" : "not installed",
                        diagnostics: [ "#{display_name}: only MCP configuration is supported in this release." ])
      end

      def launch_spec(**) = raise(UnsupportedCapability.new(:active_execution, provider: key))
      def parse_event(raw_event:) = [ NormalizedEvent.build("agent.execution.output", { "text" => raw_event.to_s[0, 4000] }) ]
    end
  end
end
