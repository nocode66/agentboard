module Agentboard
  module Providers
    # Minimal, reversible edits to provider configuration files (spec §31.2):
    # back up first, change only AgentBoard-owned entries, never replace a whole file,
    # and record a manifest so `provider remove` can undo exactly what was added.
    module ConfigEditor
      MARK_BEGIN = "# >>> agentboard (managed block — do not edit) >>>".freeze
      MARK_END = "# <<< agentboard <<<".freeze

      module_function

      def backup!(path)
        return nil unless File.exist?(path)

        dest = "#{path}.agentboard-backup-#{Time.now.utc.strftime("%Y%m%d%H%M%S")}"
        FileUtils.cp(path, dest, preserve: true)
        dest
      end

      def read_json(path)
        return {} unless File.exist?(path)

        data = JSON.parse(File.read(path))
        raise Error.validation_failed("#{path} must contain a JSON object") unless data.is_a?(Hash)

        data
      rescue JSON::ParserError => e
        raise Error.validation_failed("#{path} is not valid JSON (#{e.message[0, 80]}); refusing to modify it")
      end

      def write_json(path, data)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp-#{Process.pid}"
        File.write(tmp, JSON.pretty_generate(data) + "\n")
        File.rename(tmp, path)
      end

      # Sets data[*keys] = value only if absent or already AgentBoard-owned. Returns change hash.
      def merge_json!(path, keys, value, owned: ->(existing) { existing == value })
        data = read_json(path)
        parent = keys[0..-2].reduce(data) { |h, k| h[k] ||= {} }
        existing = parent[keys.last]
        return { path: path, keys: keys, action: "unchanged" } if existing == value
        if existing && !owned.call(existing)
          return { path: path, keys: keys, action: "skipped", reason: "an existing non-AgentBoard entry is present" }
        end

        parent[keys.last] = value
        write_json(path, data)
        { path: path, keys: keys, action: existing ? "updated" : "added" }
      end

      def delete_json!(path, keys)
        data = read_json(path)
        parent = keys[0..-2].reduce(data) { |h, k| h.is_a?(Hash) ? h[k] : nil }
        return false unless parent.is_a?(Hash) && parent.key?(keys.last)

        parent.delete(keys.last)
        write_json(path, data)
        true
      end

      # Inserts/replaces a marked text block (used for TOML where no parser is bundled).
      def upsert_block!(path, body, position: :end)
        content = File.exist?(path) ? File.read(path) : +""
        block = "#{MARK_BEGIN}\n#{body.strip}\n#{MARK_END}\n"
        if content.include?(MARK_BEGIN)
          new_content = content.sub(/#{Regexp.escape(MARK_BEGIN)}.*?#{Regexp.escape(MARK_END)}\n?/m, block)
          action = new_content == content ? "unchanged" : "updated"
        else
          new_content = position == :start ? block + "\n" + content : content + (content.end_with?("\n") || content.empty? ? "" : "\n") + "\n" + block
          action = "added"
        end
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, new_content) unless action == "unchanged"
        { path: path, action: action }
      end

      def remove_block!(path)
        return false unless File.exist?(path)

        content = File.read(path)
        new_content = content.sub(/\n?#{Regexp.escape(MARK_BEGIN)}.*?#{Regexp.escape(MARK_END)}\n?/m, "\n")
        return false if new_content == content

        File.write(path, new_content)
        true
      end

      def manifest_path(root, provider) = File.join(root.to_s, ".agentboard", "manifests", "#{provider}.json")

      def write_manifest!(root, provider, manifest)
        path = manifest_path(root, provider)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(manifest.merge("written_at" => Time.now.utc.iso8601)))
        path
      end

      def read_manifest(root, provider)
        path = manifest_path(root, provider)
        File.exist?(path) ? JSON.parse(File.read(path)) : nil
      end
    end
  end
end
require "fileutils"
