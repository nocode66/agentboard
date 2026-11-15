require "agentboard/subprocess"
require "agentboard/providers/types"
require "agentboard/providers/base"
require "agentboard/providers/registry"
require "agentboard/providers/config_editor"
require "agentboard/providers/fake"
require "agentboard/providers/claude_code"
require "agentboard/providers/codex"
require "agentboard/providers/cursor"
require "agentboard/providers/generic_cli"

module Agentboard
  module Providers
    def self.registry
      @registry ||= Registry.new.tap do |r|
        r.register(:fake, Fake)
        r.register(:claude, ClaudeCode)
        r.register(:codex, Codex)
        r.register(:cursor, Cursor)
        r.register(:gemini, GenericCli.for(key: "gemini", binary: "gemini", display: "Gemini CLI"))
        r.register(:opencode, GenericCli.for(key: "opencode", binary: "opencode", display: "OpenCode"))
        r.register(:copilot, GenericCli.for(key: "copilot", binary: "copilot", display: "GitHub Copilot CLI"))
      end
    end
  end
end
