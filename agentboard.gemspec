require_relative "lib/agentboard/version"

Gem::Specification.new do |spec|
  spec.name        = "agentboard"
  spec.version     = Agentboard::VERSION
  spec.authors     = [ "PIRUBY" ]
  spec.homepage    = "https://agent-board.live"
  spec.summary     = "Local-first, AI-native ticket board and agent orchestration engine for Rails."
  spec.description = <<~DESC
    AgentBoard installs into a Rails application and connects tickets to coding agents
    (Claude Code, OpenAI Codex, Cursor and third-party adapters) through MCP, provider hooks,
    a supervised runtime daemon, isolated Git worktrees and evidence-based completion policies.
  DESC
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "https://agent-board.live/docs"
  spec.metadata["source_code_uri"] = "https://github.com/nocode66/agentboard"
  spec.metadata["changelog_uri"] = "https://github.com/nocode66/agentboard/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/nocode66/agentboard/issues"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib,exe}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end
  spec.bindir = "exe"
  spec.executables = [ "agentboard" ]

  spec.add_dependency "rails", ">= 7.2", "< 9"
  spec.add_dependency "turbo-rails", ">= 2.0"
  spec.add_dependency "stimulus-rails", ">= 1.3"
  spec.add_dependency "mcp", ">= 0.25", "< 1"
  spec.add_dependency "thor", ">= 1.3"
end
