module Agentboard
  module Providers
    # Cursor: passive-first (spec §26.4). Registers the MCP server in `.cursor/mcp.json`.
    # Active launch/resume stay disabled until a tested provider interface exists.
    class Cursor < Base
      def self.key = :cursor
      def self.display_name = "Cursor"

      def probe(environment: ENV)
        bin = which("cursor-agent") || which("cursor")
        version = bin && run_version([ bin, "--version" ]).to_s[/\d+\.\d+\.\d+/]
        ProbeResult.new(provider: key, installed: !bin.nil?, version: version, authenticated: nil,
                        supported_capabilities: %i[mcp], validation: bin ? "passive only" : "not installed",
                        diagnostics: [ "Cursor active execution is not enabled: no fixture-validated agent interface." ])
      end

      def install_passive_hooks(project:, root:)
        path = File.join(root, ".cursor", "mcp.json")
        backups = [ ConfigEditor.backup!(path) ].compact
        entry = { "command" => "bundle", "args" => [ "exec", "agentboard", "mcp", "serve", "--root", root.to_s ] }
        change = ConfigEditor.merge_json!(path, %w[mcpServers agentboard], entry, owned: ->(e) { e.is_a?(Hash) && Array(e["args"]).include?("agentboard") })
        manifest = { "provider" => key, "mcp" => { "path" => path, "keys" => %w[mcpServers agentboard] } }
        ConfigEditor.write_manifest!(root, key, manifest)
        SetupResult.new(provider: key, changes: [ change ], manifest: manifest, backups: backups, warnings: [ "Cursor hooks are not installed." ])
      end

      def remove_passive_hooks(project:, root:, manifest: nil)
        m = (manifest || ConfigEditor.read_manifest(root, key) || {})["mcp"]
        m && ConfigEditor.delete_json!(m["path"], m["keys"]) ? [ m["path"] ] : []
      end

      def parse_hook(event_name:, payload:)
        [ NormalizedEvent.build("agent.provider.unknown", { "event" => event_name.to_s[0, 64] }) ]
      end

      def launch_spec(**) = raise(UnsupportedCapability.new(:active_execution, provider: key))
      def parse_event(raw_event:) = [ NormalizedEvent.build("agent.execution.output", { "text" => raw_event.to_s[0, 4000] }) ]
    end
  end
end
