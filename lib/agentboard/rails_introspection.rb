module Agentboard
  # Static Rails metadata via Prism — never boots or executes repository code (spec §10).
  module RailsIntrospection
    HTTP_VERBS = %w[get post put patch delete match].freeze

    module_function

    # Returns [{ verb:, path:, kind: }] from config/routes.rb.
    def routes(root)
      path = File.join(root.to_s, "config", "routes.rb")
      return [] unless File.file?(path)

      require "prism"
      found = []
      walk = ->(node) do
        if node.is_a?(Prism::CallNode) && node.receiver.nil?
          name = node.name.to_s
          first = node.arguments&.arguments&.first
          label = case first
                  when Prism::SymbolNode then first.unescaped
                  when Prism::StringNode then first.unescaped
                  when Prism::KeywordHashNode then first.elements.first&.key&.slice
                  end
          if %w[resources resource namespace scope].include?(name) && label
            found << { verb: name, path: label.to_s, kind: "resource" }
          elsif HTTP_VERBS.include?(name) && label
            found << { verb: name.upcase, path: label.to_s, kind: "route" }
          elsif name == "root"
            found << { verb: "GET", path: "/", kind: "root" }
          end
        end
        node.compact_child_nodes.each { |c| walk.(c) }
      end
      walk.(Prism.parse_file(path).value)
      found.first(300)
    rescue StandardError, LoadError
      []
    end

    # Table names created by migrations (static scan).
    def migration_tables(root)
      Dir[File.join(root.to_s, "db", "migrate", "*.rb")].sort.last(200).flat_map do |f|
        File.read(f, 200_000).scan(/create_table\s+[:"']([a-z0-9_]+)/).flatten
      end.uniq
    rescue StandardError
      []
    end
  end
end
