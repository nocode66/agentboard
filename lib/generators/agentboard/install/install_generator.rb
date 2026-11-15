require "rails/generators"
require "rails/generators/active_record"

module Agentboard
  module Generators
    # bin/rails generate agentboard:install
    # Idempotent: never overwrites existing files unless --force (Thor shows a diff/conflict prompt otherwise).
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration
      source_root File.expand_path("templates", __dir__)

      def copy_initializer
        template "initializer.rb", "config/initializers/agentboard.rb"
      end

      def copy_config
        template "config.yml", "config/agentboard.yml"
      end

      def create_local_dirs
        %w[workflows instructions policies cache].each { |d| empty_directory ".agentboard/#{d}" }
        copy_file "feature_delivery.yml", ".agentboard/workflows/feature_delivery.yml"
      end

      def copy_migrations
        rake "agentboard:install:migrations"
      end

      def mount_engine
        routes = File.join(destination_root, "config/routes.rb")
        return if File.exist?(routes) && File.read(routes).include?("Agentboard::Engine")

        route "# AgentBoard dashboard: development only by default\nif Rails.env.development?\n  mount Agentboard::Engine, at: \"/agentboard\"\nend"
      end

      def ignore_local_state
        path = File.join(destination_root, ".gitignore")
        entries = [ "/.agentboard/worktrees/", "/.agentboard/logs/", "/.agentboard/cache/", "/.agentboard/spool/", "/.agentboard/manifests/", "*.agentboard-backup-*" ]
        existing = File.exist?(path) ? File.read(path).lines.map(&:strip) : []
        missing = entries - existing
        return if missing.empty?

        block = "\n# AgentBoard local state\n#{missing.join("\n")}\n"
        File.exist?(path) ? append_to_file(".gitignore", block) : create_file(".gitignore", block.lstrip)
      end

      def write_manifest
        create_file ".agentboard/generated_manifest.json", JSON.pretty_generate(
          "generator" => "agentboard:install", "version" => Agentboard::VERSION,
          "files" => %w[config/initializers/agentboard.rb config/agentboard.yml .agentboard/workflows/feature_delivery.yml]
        ) + "\n"
      end

      def show_next_steps
        say <<~TEXT

          AgentBoard installed. Next:
            bin/rails db:migrate
            bundle exec agentboard doctor
            bundle exec agentboard provider setup claude   # and/or codex
            bundle exec agentboard daemon start
            open http://localhost:3000/agentboard
        TEXT
      end
    end
  end
end
