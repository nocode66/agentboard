module Agentboard
  module Git
    # Creates one dedicated branch + worktree per execution (spec §8, §29.2):
    #   .agentboard/worktrees/AB-142-exec-001   on branch agentboard/AB-142/exec-001
    # Worktrees are source-control isolation only — they are NOT security sandboxes.
    class WorktreeManager
      Worktree = Struct.new(:path, :branch, :base_sha, keyword_init: true)

      attr_reader :repository, :workspace

      def initialize(repository:, workspace:)
        @repository = repository
        @workspace = File.expand_path(workspace.to_s)
      end

      def self.name_for(ticket_key, attempt)
        raise Error.validation_failed("Invalid ticket key") unless ticket_key.to_s.match?(/\A[A-Z][A-Z0-9_-]*-\d+\z/)

        suffix = "exec-#{attempt.to_i.to_s.rjust(3, "0")}"
        [ "#{ticket_key}-#{suffix}", "agentboard/#{ticket_key}/#{suffix}" ]
      end

      def create!(ticket_key:, attempt:, base_ref: "HEAD")
        dir_name, branch = self.class.name_for(ticket_key, attempt)
        FileUtils.mkdir_p(workspace, mode: 0o700)
        ensure_ignored!
        path = PathGuard.within!(workspace, dir_name)
        raise Error.workspace_conflict("Worktree #{dir_name} already exists") if File.exist?(path)

        base_sha = repository.git("rev-parse", "--verify", "#{base_ref}^{commit}").strip
        repository.git("worktree", "add", "-b", branch, path, base_sha)
        Worktree.new(path: path, branch: branch, base_sha: base_sha)
      rescue Repository::CommandFailed => e
        raise Error.workspace_conflict(e.message)
      end

      def head_sha(path) = repository.head_sha(chdir: guard(path))
      def clean?(path) = repository.clean?(chdir: guard(path))

      # Commits any pending work in the worktree on behalf of the execution, so the result is
      # bound to an immutable SHA. Returns the new head.
      def snapshot!(path, message:)
        dir = guard(path)
        return head_sha(dir) if repository.clean?(chdir: dir)

        repository.git("add", "-A", chdir: dir)
        repository.git("-c", "user.name=AgentBoard", "-c", "user.email=agentboard@localhost", "commit", "--no-verify", "-m", message, chdir: dir)
        head_sha(dir)
      end

      def changes(path, base_sha)
        dir = guard(path)
        head = head_sha(dir)
        { head_sha: head, files: repository.changed_files(base_sha, head, chdir: dir), stat: repository.diff_stat(base_sha, head, chdir: dir) }
      end

      # Removal requires: no uncommitted changes unless force (explicit confirmation).
      def remove!(path, force: false, delete_branch: false)
        dir = guard(path)
        return false unless File.directory?(dir)
        if !force && !repository.clean?(chdir: dir)
          raise Error.workspace_conflict("Worktree has uncommitted changes; confirm with --force")
        end

        branch = repository.current_branch(chdir: dir)
        args = [ "worktree", "remove" ]
        args << "--force" if force
        repository.git(*args, dir)
        repository.git("branch", "-D", branch, allow_failure: true) if delete_branch && branch.start_with?("agentboard/")
        true
      end

      def prune! = repository.git("worktree", "prune")

      def list
        # Compare real paths: on macOS /var and /tmp are symlinks into /private.
        real = File.exist?(workspace) ? File.realpath(workspace) : workspace
        repository.worktrees.select { |w| w["worktree"].to_s.start_with?(real) || w["worktree"].to_s.start_with?(workspace) }
      end

      private

      def guard(path) = PathGuard.within!(workspace, path)

      def ensure_ignored!
        exclude = File.join(repository.git("rev-parse", "--git-common-dir").strip.then { |d| File.expand_path(d, repository.root) }, "info", "exclude")
        top = File.realpath(repository.toplevel)
        ws = File.realpath(workspace)
        return unless ws.start_with?(top + "/") # workspace outside repo
        rel = ws.delete_prefix(top + "/")

        # Local AgentBoard state never shows up as untracked files in the main checkout.
        wanted = [ "/#{rel}/" ]
        state_dir = File.dirname(ws)
        if File.basename(state_dir) == ".agentboard"
          base = state_dir.delete_prefix(top + "/")
          wanted += %w[logs cache spool manifests].map { |d| "/#{base}/#{d}/" }
        end
        FileUtils.mkdir_p(File.dirname(exclude))
        lines = File.exist?(exclude) ? File.read(exclude).lines.map(&:strip) : []
        missing = wanted - lines
        File.open(exclude, "a") { |f| missing.each { |l| f.puts(l) } } if missing.any?
      end
    end
  end
end
require "fileutils"
