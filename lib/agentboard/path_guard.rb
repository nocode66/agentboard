module Agentboard
  # Canonicalizes paths and rejects traversal or symlink escape outside an allowed root
  # (spec §29.2, §30.2). Used for every AgentBoard-managed file operation.
  module PathGuard
    module_function

    def within!(root, path)
      root_real = File.realpath(root.to_s)
      candidate = File.expand_path(path.to_s, root_real)
      # Resolve the deepest existing ancestor so symlinks anywhere in the chain are followed.
      probe = candidate
      probe = File.dirname(probe) until File.exist?(probe) || probe == "/"
      resolved = File.join(File.realpath(probe), candidate.delete_prefix(probe))
      resolved = File.expand_path(resolved)
      unless resolved == root_real || resolved.start_with?(root_real + File::SEPARATOR)
        raise Error.validation_failed("Path escapes the allowed workspace", path: path.to_s)
      end

      resolved
    end

    def safe_relative?(path)
      p = path.to_s
      !p.empty? && !p.start_with?("/") && !p.split(%r{[/\\]}).include?("..") && !p.include?("\0")
    end
  end
end
