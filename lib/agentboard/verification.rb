require "agentboard/subprocess"

module Agentboard
  module Verification
    # Administrator-defined allowlist of verification commands (spec §29.1).
    # Workflows and agents can reference commands only by name.
    class Catalog
      Command = Struct.new(:name, :argv, :timeout_seconds, :required, :working_directory, :env, keyword_init: true) do
        def digest = Ids.canonical_digest(name: name, argv: argv, cwd: working_directory, env: env)
      end

      attr_reader :commands

      def initialize(hash)
        @commands = hash.to_h.to_h do |name, spec|
          spec = spec.to_h.transform_keys(&:to_s)
          argv = spec["argv"]
          unless argv.is_a?(Array) && argv.any? && argv.all? { |a| a.is_a?(String) && !a.empty? }
            raise Error.validation_failed("verification command #{name} needs a non-empty argv array of strings")
          end

          [ name.to_s, Command.new(name: name.to_s, argv: argv.freeze, timeout_seconds: (spec["timeout_seconds"] || 600).to_i.clamp(1, 86_400),
                                   required: spec.fetch("required", true) != false, working_directory: spec["working_directory"] || "worktree",
                                   env: (spec["env"] || {}).to_h.transform_keys(&:to_s)) ]
        end
      end

      def fetch(name)
        commands.fetch(name.to_s) { raise Error.policy_denied("Command #{name} is not in the approved catalog") }
      end

      def names = commands.keys
      def required_names = commands.values.select(&:required).map(&:name)
      def each(&) = commands.values.each(&)
    end

    # Executes catalog commands directly (no shell) inside a directory and binds the result
    # to the exact head SHA. A dirty tree is never bound to a commit.
    class Runner
      Outcome = Struct.new(:name, :status, :exit_code, :commit_sha, :command_digest, :output, :duration, :required, keyword_init: true)

      def initialize(catalog:, max_bytes: 512 * 1024)
        @catalog = catalog
        @max_bytes = max_bytes
      end

      def run(name, chdir:, cancel_check: nil, timeout: nil, &on_chunk)
        cmd = @catalog.fetch(name)
        repo = Git::Repository.new(chdir)
        head = repo.head_sha(chdir: chdir)
        dirty = !repo.clean?(chdir: chdir)
        limit = [ cmd.timeout_seconds, timeout ].compact.min
        env = cmd.env.merge("CI" => "1", "AGENTBOARD_VERIFICATION" => "1")
        argv = cmd.argv
        container = nil
        if ContainerSandbox.enabled?
          raise Error.capability_unavailable("Container sandbox requested but #{ContainerSandbox.settings["runtime"]} is not running") unless ContainerSandbox.available?

          container = ContainerSandbox.container_name
          argv = ContainerSandbox.wrap(cmd.argv, workdir: chdir, env: env, name: container)
        end
        result = Subprocess.run(argv, chdir: chdir, timeout: limit, env: env, max_bytes: @max_bytes, cancel_check: cancel_check, &on_chunk)
        ContainerSandbox.kill(container) if container && (result.timed_out || result.cancelled)
        # If the tree changed during the run, the result cannot be attributed to `head`.
        head_after = repo.head_sha(chdir: chdir)
        bound_sha = (dirty || head_after != head) ? "unbound:#{head}" : head
        status =
          if result.timed_out then "timeout"
          elsif result.cancelled then "error"
          elsif result.exit_code == 127 && result.output.start_with?("command not found") then "error"
          elsif result.success? then "passed"
          else "failed"
          end
        Outcome.new(name: cmd.name, status: status, exit_code: result.exit_code, commit_sha: bound_sha, command_digest: cmd.digest,
                    output: result.output, duration: result.duration, required: cmd.required)
      end
    end
  end
end
