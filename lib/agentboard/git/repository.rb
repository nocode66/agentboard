module Agentboard
  module Git
    # Thin, argv-only wrapper over the git CLI. Never interpolates into a shell.
    class Repository
      class CommandFailed < StandardError; end

      attr_reader :root

      def initialize(root)
        @root = File.expand_path(root.to_s)
      end

      def git(*args, chdir: root, allow_failure: false, env: {})
        out, err, status = Open3.capture3(safe_env.merge(env), "git", *args.map(&:to_s), chdir: chdir)
        unless status.success? || allow_failure
          raise CommandFailed, "git #{args.first} failed: #{Redactor.redact(err.strip)[0, 500]}"
        end

        allow_failure ? [ out, err, status ] : out
      end

      def repository? = git("rev-parse", "--is-inside-work-tree", allow_failure: true)[2].success?
      def toplevel = git("rev-parse", "--show-toplevel").strip
      def head_sha(chdir: root) = git("rev-parse", "HEAD", chdir: chdir).strip
      def current_branch(chdir: root) = git("rev-parse", "--abbrev-ref", "HEAD", chdir: chdir).strip

      def default_branch
        out, _e, st = git("symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD", allow_failure: true)
        return out.strip.sub(%r{\Aorigin/}, "") if st.success? && out.present?

        %w[main master trunk].find { |b| git("rev-parse", "--verify", "--quiet", "refs/heads/#{b}", allow_failure: true)[2].success? } || current_branch
      rescue CommandFailed
        "main"
      end

      def clean?(chdir: root) = git("status", "--porcelain", chdir: chdir).strip.empty?

      # Returns the full SHA if the object exists as a commit in this repository.
      def resolve_commit(sha)
        return nil unless sha.to_s.match?(/\A[0-9a-fA-F]{4,64}\z/)

        out, _e, st = git("rev-parse", "--verify", "--quiet", "#{sha}^{commit}", allow_failure: true)
        st.success? ? out.strip : nil
      end

      def commit_subject(sha) = git("log", "-1", "--format=%s", sha).strip
      def ancestor?(ancestor, descendant) = git("merge-base", "--is-ancestor", ancestor, descendant, allow_failure: true)[2].success?

      def tracked_files(chdir: root) = git("ls-files", "-z", chdir: chdir).split("\0")

      def changed_files(base, head, chdir: root)
        git("diff", "--name-only", "-z", "#{base}..#{head}", chdir: chdir).split("\0")
      end

      def diff_stat(base, head, chdir: root)
        out = git("diff", "--shortstat", "#{base}..#{head}", chdir: chdir)
        {
          files: out[/(\d+) files? changed/, 1].to_i,
          insertions: out[/(\d+) insertions?/, 1].to_i,
          deletions: out[/(\d+) deletions?/, 1].to_i
        }
      end

      def log(limit: 20, chdir: root, range: nil)
        args = [ "log", "-#{limit.to_i}", "--format=%H%x1f%an%x1f%aI%x1f%s" ]
        args << range if range
        git(*args, chdir: chdir).lines.map do |line|
          sha, author, date, subject = line.chomp.split("\x1f", 4)
          { sha: sha, author: author, date: date, subject: subject }
        end
      rescue CommandFailed
        []
      end

      def worktrees
        git("worktree", "list", "--porcelain").split("\n\n").map do |block|
          block.lines.each_with_object({}) do |line, h|
            k, v = line.chomp.split(" ", 2)
            h[k] = v || true
          end
        end
      end

      private

      # Prevent user/global hooks or pagers from altering behaviour.
      def safe_env
        { "GIT_TERMINAL_PROMPT" => "0", "GIT_PAGER" => "cat", "LC_ALL" => "C" }
      end
    end
  end
end
