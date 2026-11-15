module Agentboard
  module Runtime
    # Drives one execution attempt through the pipeline of spec §8:
    #   validate → worktree → context → launch → stream → snapshot → verify → review handoff.
    # Runs inside the daemon process (never inside a web worker).
    class ExecutionRunner
      CANCEL_POLL_SECONDS = 0.5
      HEARTBEAT_SECONDS = 5

      attr_reader :execution

      def initialize(execution, config: Agentboard.config)
        @execution = execution
        @config = config
        @last_cancel_poll = 0
        @last_heartbeat = 0
        @cancelled = false
      end

      def call
        prepare!
        return finish_cancelled! if cancel_requested?

        outcome = launch_and_stream!
        return finish_cancelled! if outcome == :cancelled
        return fail!("execution_timeout", "Execution exceeded #{timeout}s") if outcome == :timeout

        head = snapshot!
        provider_ok = outcome == :succeeded
        unless provider_ok
          return fail!("provider_failed", "Provider exited with code #{execution.exit_code.inspect}")
        end

        verify!(head)
      rescue Agentboard::Error => e
        fail!(e.code.downcase, e.message)
      rescue StandardError => e
        Agentboard.logger.error("[agentboard] execution #{execution.id} crashed: #{e.class}: #{Redactor.redact(e.message)}")
        Agentboard.logger.error(e.backtrace.first(8).join("\n")) if e.backtrace
        fail!("internal_error", "#{e.class}: #{Redactor.redact(e.message)[0, 300]}")
      ensure
        @log&.close
      end

      private

      def ticket = execution.ticket
      def project = ticket.project
      def provider = @provider ||= Providers.registry.fetch(execution.provider_key)
      # The tighter of the runtime limit and a per-step workflow limit.
      def timeout = [ (@config.runtime["execution_timeout_seconds"] || 3600).to_i, execution.metadata["timeout_seconds"]&.to_i ].compact.min

      def prepare!
        Executions.transition!(execution, "preparing")
        repo = project.repository
        manager = Git::WorktreeManager.new(repository: repo, workspace: @config.workspace_path)
        resumed = resume_source
        worktree = if resumed
          # Resume continues in the previous attempt's worktree (it is terminal, so not shared).
          Git::WorktreeManager::Worktree.new(path: resumed.worktree_path, branch: resumed.branch, base_sha: resumed.base_sha)
        elsif execution.worktree_path.present? && File.directory?(execution.worktree_path)
          Git::WorktreeManager::Worktree.new(path: execution.worktree_path, branch: execution.branch, base_sha: execution.base_sha)
        else
          manager.create!(ticket_key: ticket.key, attempt: execution.attempt, base_ref: base_ref)
        end
        @manager = manager
        log_dir = @config.root_path.join(".agentboard", "logs", execution.id)
        FileUtils.mkdir_p(log_dir, mode: 0o700)
        context_dir = @config.root_path.join(".agentboard", "cache", "contexts")
        FileUtils.mkdir_p(context_dir, mode: 0o700)

        package = ContextBuilder.call(ticket: ticket, repository: repo, chdir: worktree.path, action: execution.action,
                                      handoff: execution.metadata["handoff"],
                                      max_tokens: (execution.agent_profile&.config || {}).fetch("context_tokens", 12_000))
        record_snapshot(repo, worktree)
        context_path = context_dir.join("#{execution.id}.md")
        File.write(context_path, package.text)
        Artifact.create!(ticket: ticket, execution: execution, kind: "context", uri: "file:#{context_path}", sha256: package.digest,
                         title: "Context package (#{package.tokens_estimate} tokens#{package.truncated ? ", truncated" : ""})",
                         provenance: "confirmed", metadata: package.to_h.transform_keys(&:to_s))
        execution.update_columns(worktree_path: worktree.path, branch: worktree.branch, base_sha: worktree.base_sha,
                          context_path: context_path.to_s, context_digest: package.digest, log_path: log_dir.join("agent.log").to_s)
        EventStore.append!(type: "git.worktree_created", aggregate: execution, ticket: ticket, execution: execution,
                           payload: { path: worktree.path, branch: worktree.branch, base_sha: worktree.base_sha })

        session = execution.agent_session
        SessionAssociation.link!(session: session, ticket: ticket, source: "runtime", actor: Authorization.system_actor) if session
        if ticket.reload.status == "claimed"
          Tickets.transition!(ticket: ticket, to: "in_progress", actor: Authorization.system_actor)
        end
        @prompt = build_prompt(package)
      end

      def base_ref
        execution.metadata["base_ref"].presence || "HEAD"
      end

      def record_snapshot(repo, worktree)
        return if RepositorySnapshot.exists?(project_id: project.id, commit_sha: worktree.base_sha)

        builder = ContextBuilder.new(ticket: ticket, repository: repo, max_tokens: 1_000, chdir: worktree.path, action: "snapshot", handoff: nil)
        RepositorySnapshot.create!(project: project, commit_sha: worktree.base_sha, metadata: builder.snapshot_metadata)
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      def resume_source
        id = execution.metadata["resume_of"]
        return nil unless id

        prev = Execution.find(id)
        raise Error.invalid_transition("Cannot resume: previous attempt is still active") unless prev.terminal?
        raise Error.workspace_conflict("Cannot resume: worktree of the previous attempt is gone") unless prev.worktree_path && File.directory?(prev.worktree_path)
        if Execution.active.where(worktree_path: prev.worktree_path).where.not(id: execution.id).exists?
          raise Error.workspace_conflict("Worktree is in use by another execution")
        end

        prev
      end

      def build_prompt(package)
        action_text = {
          "plan" => "Produce an implementation plan for the ticket. Do not modify files.",
          "implement" => "Implement the ticket in this working directory and commit your changes with a descriptive message.",
          "review" => "Review the changes between the base commit and HEAD for correctness, security and test coverage. Report findings; do not modify files.",
          "fix_tests" => "Make the failing verification commands pass. Commit your changes.",
          "summarize" => "Summarize the current state of the work for a human reviewer."
        }.fetch(execution.action, "Work on the ticket.")
        <<~PROMPT
          You are working on ticket #{ticket.key} managed by AgentBoard.
          #{action_text}
          AgentBoard runs verification independently; your own claims of success are not evidence.

          #{package.text}
        PROMPT
      end

      def launch_and_stream!
        spec = if execution.metadata["resume_of"]
          provider.resume_spec(execution: execution, worktree: execution.worktree_path,
                               input: execution.metadata["resume_message"].presence || "Continue the task.")
        else
          provider.launch_spec(execution: execution, worktree: execution.worktree_path, context_path: execution.context_path, prompt: @prompt)
        end
        @log = File.open(execution.log_path, "ab", 0o600)
        max_bytes = @config.runtime["max_log_bytes"].to_i
        argv = spec.argv
        cli_env = {}
        if execution.metadata["isolation"] == "container"
          cli_env = AgentContainer.cli_env(spec)
          AgentContainer.ensure_network!
          @container = "agentboard-exec-#{execution.id.delete("-")[-16..]}"
          argv = AgentContainer.wrap(spec, execution: execution, name: @container)
          execution.update_columns(metadata: execution.metadata.merge("container" => @container, "image" => AgentContainer.image))
          EventStore.append!(type: "agent.execution.container_started", aggregate: execution, ticket: ticket, execution: execution,
                             payload: { container: @container, image: AgentContainer.image, network: AgentContainer.network_name,
                                        egress: AgentContainer.egress_allowlist })
        end
        handle = Subprocess.spawn(argv, chdir: spec.chdir, env: spec.env.to_h.merge(cli_env).merge("AGENTBOARD_EXECUTION_ID" => execution.id),
                                  passthrough_env: (spec.passthrough_env || []) + %w[DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG DOCKER_CERT_PATH DOCKER_TLS_VERIFY],
                                  stdin_data: spec.stdin_data)
        execution.update_columns(pid: handle[:pid], pgid: handle[:pgid], process_fingerprint: Subprocess.fingerprint(handle[:pid]), heartbeat_at: Time.current)
        Executions.transition!(execution, "running")

        started = Subprocess.monotonic
        terminal_status = nil
        buffer = +""
        reader = handle[:reader]
        result = nil
        loop do
          if Subprocess.monotonic - started > timeout
            Subprocess.terminate(handle[:pgid], grace: grace)
            AgentContainer.remove(@container)
            result = :timeout
            break
          end
          if cancel_requested?
            Subprocess.terminate(handle[:pgid], grace: grace)
            AgentContainer.remove(@container) # killing the docker CLI does not stop the container
            result = :cancelled
            break
          end
          heartbeat!
          next unless IO.select([ reader ], nil, nil, 0.2)

          chunk = begin
            reader.read_nonblock(65_536)
          rescue IO::WaitReadable
            next
          rescue EOFError
            break
          end
          buffer << chunk.force_encoding("UTF-8").scrub
          while (idx = buffer.index("\n"))
            line = buffer.slice!(0..idx)
            status = handle_line(line, max_bytes)
            terminal_status = status if status
          end
        end
        handle_line(buffer, max_bytes) if buffer.present? && result.nil?
        @last_heartbeat = 0
        heartbeat! # final resource sample
        reader.close unless reader.closed?
        _, status = ::Process.wait2(handle[:pid])
        execution.update_columns(exit_code: status.exitstatus)
        return result if result

        terminal_status == "failed" || !status.success? ? :failed : :succeeded
      end

      def handle_line(line, max_bytes)
        redacted, count = Redactor.redact_with_count(line)
        if execution.log_bytes < max_bytes
          @log.write(redacted)
          @log.flush
          execution.log_bytes += redacted.bytesize
        elsif !execution.log_truncated
          @log.write("\n[agentboard: log truncated at #{max_bytes} bytes]\n")
          execution.log_truncated = true
        end
        if count.positive?
          EventStore.append!(type: "security.secret_redacted", aggregate: execution, ticket: ticket, execution: execution,
                             payload: { where: "provider_output", redactions: count })
        end
        status = nil
        provider.parse_event(raw_event: redacted).each do |ev|
          Executions.record_provider_event!(execution, ev)
          status = ev.status if ev.terminal
          if ev.status == "waiting_for_permission"
            # Print-mode providers do not block on permission; the request is recorded and
            # surfaced. Interactive permission bridging requires a provider protocol.
            execution.update_columns(metadata: execution.metadata.merge("permission_requests" => execution.metadata["permission_requests"].to_i + 1))
          end
        end
        status
      ensure
        execution.update_columns(log_bytes: execution.log_bytes, log_truncated: execution.log_truncated)
      end

      def heartbeat!
        now = Subprocess.monotonic
        return if now - @last_heartbeat < HEARTBEAT_SECONDS

        @last_heartbeat = now
        attrs = { heartbeat_at: Time.current }
        if execution.pgid && (usage = Subprocess.group_usage(execution.pgid))
          @peak_rss = [ @peak_rss.to_i, usage[:rss_kb] ].max
          @cpu = [ @cpu.to_f, usage[:cpu_seconds] ].max
          attrs[:metadata] = execution.metadata.merge("resources" => { "peak_rss_kb" => @peak_rss, "cpu_seconds" => @cpu.round(2),
                                                                       "processes" => usage[:processes] })
          execution.metadata = attrs[:metadata]
        end
        execution.update_columns(attrs)
      end

      def cancel_requested?
        return true if @cancelled

        now = Subprocess.monotonic
        return false if now - @last_cancel_poll < CANCEL_POLL_SECONDS

        @last_cancel_poll = now
        @cancelled = Execution.where(id: execution.id).where.not(cancel_requested_at: nil).exists?
      end

      def grace = @config.runtime["cancel_grace_seconds"].to_i

      # Bind whatever the agent produced to an immutable commit (evidence), even on failure.
      def snapshot!
        return nil unless execution.worktree_path && File.directory?(execution.worktree_path)

        head = @manager.snapshot!(execution.worktree_path, message: "#{ticket.key}: AgentBoard snapshot (#{execution.provider_key} exec-#{execution.attempt})")
        changes = @manager.changes(execution.worktree_path, execution.base_sha)
        execution.update_columns(head_sha: head)
        if changes[:files].any?
          Artifact.create!(ticket: ticket, execution: execution, kind: "commit", uri: "git:#{head}", commit_sha: head,
                           title: "#{changes[:stat][:files]} files (+#{changes[:stat][:insertions]}/−#{changes[:stat][:deletions]})",
                           provenance: "git_observed",
                           metadata: { "verified_in_repo" => true, "branch" => execution.branch, "files" => changes[:files].first(200), "stat" => changes[:stat] })
          Approvals.invalidate_stale!(ticket: ticket, head_sha: head)
        end
        EventStore.append!(type: "git.snapshot", aggregate: execution, ticket: ticket, execution: execution, provenance: "git_observed",
                           payload: { head_sha: head, base_sha: execution.base_sha, files: changes[:files].first(50), stat: changes[:stat] })
        @changed = changes[:files].any?
        head
      end

      def verify!(head)
        if %w[plan review summarize].include?(execution.action) || !@changed
          Executions.transition!(execution, "verifying")
          Executions.transition!(execution, "completed", summary: last_summary)
          return execution
        end

        Executions.transition!(execution, "verifying")
        if ticket.reload.status == "in_progress"
          Tickets.transition!(ticket: ticket, to: "testing", actor: Authorization.system_actor)
        end
        results = VerificationService.run_catalog!(execution: execution, chdir: execution.worktree_path, cancel_check: -> { cancel_requested? })
        return finish_cancelled! if cancel_requested?

        required_ok = results.select(&:required).all?(&:passed?)
        if required_ok
          Executions.transition!(execution, "completed", summary: last_summary)
          if ticket.reload.status == "testing"
            Tickets.transition!(ticket: ticket, to: "review", actor: Authorization.system_actor, head_sha: head)
            Approvals.request_review!(ticket: ticket, actor: Authorization.system_actor, head_sha: head, summary: last_summary)
          end
        else
          failed = results.reject(&:passed?).map(&:name)
          Executions.transition!(execution, "failed", failure_code: "verification_failed", failure_message: "Checks failed: #{failed.join(", ")}",
                                                      summary: last_summary)
          Tickets.transition!(ticket: ticket, to: "in_progress", actor: Authorization.system_actor) if ticket.reload.status == "testing"
        end
        release_lease!
        execution
      end

      def last_summary
        Event.where(execution_id: execution.id, event_type: %w[agent.execution.result agent.execution.message])
             .order(received_at: :desc).limit(1).pick(:payload)&.then { |p| p["summary"].presence || p["text"] }.to_s[0, 4000]
      end

      def release_lease!
        session = execution.agent_session
        ticket.leases.live.where(agent_session_id: session&.id).update_all(released_at: Time.current, release_reason: "execution_finished", updated_at: Time.current)
      end

      def finish_cancelled!
        execution.reload
        return execution if execution.terminal?

        Executions.transition!(execution, "cancelled", cancel_reason: execution.cancel_reason || "cancelled")
        release_lease!
        execution
      end

      def fail!(code, message)
        execution.reload
        return execution if execution.terminal?

        to = execution.status == "queued" ? "failed" : "failed"
        Executions.transition!(execution, to, failure_code: code.to_s[0, 64], failure_message: message.to_s[0, 2000])
        release_lease!
        execution
      rescue StandardError => e
        Agentboard.logger.error("[agentboard] could not mark #{execution.id} failed: #{e.class}")
        execution
      end
    end
  end
end
