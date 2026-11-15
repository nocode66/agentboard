module Agentboard
  # Runs catalog commands and persists results bound to the tested commit (spec §29.1).
  module VerificationService
    module_function

    def run_catalog!(execution:, chdir:, names: nil, cancel_check: nil, timeout: nil)
      catalog = Agentboard.config.verification_catalog
      runner = Verification::Runner.new(catalog: catalog)
      (names || catalog.names).map do |name|
        cmd = catalog.fetch(name)
        record = VerificationResult.create!(execution: execution, ticket_id: execution.ticket_id, name: name, status: "running",
                                            required: cmd.required, command_digest: cmd.digest,
                                            commit_sha: Git::Repository.new(chdir).head_sha(chdir: chdir), started_at: Time.current)
        EventStore.append!(type: "verification.started", aggregate: execution, ticket: execution.ticket, execution: execution,
                           payload: { name: name, result_id: record.id, commit_sha: record.commit_sha })
        outcome = runner.run(name, chdir: chdir, cancel_check: cancel_check, timeout: timeout)
        log = write_log(execution, name, outcome.output)
        record.update!(status: outcome.status, exit_code: outcome.exit_code, commit_sha: outcome.commit_sha,
                       output_excerpt: outcome.output.to_s.last(4000), duration_seconds: outcome.duration,
                       finished_at: Time.current, log_artifact_id: log&.id)
        EventStore.append!(type: "verification.#{outcome.status == "passed" ? "passed" : "failed"}", aggregate: execution,
                           ticket: execution.ticket, execution: execution,
                           payload: { name: name, result_id: record.id, status: outcome.status, exit_code: outcome.exit_code,
                                      commit_sha: outcome.commit_sha, duration: outcome.duration.round(2) })
        record
      end
    end

    # Passive/manual flow: verify the project's checked-out HEAD (e.g. after a developer's
    # own Claude/Codex session). Creates a `verify` execution so results have an owner.
    def verify_repository!(ticket:, actor:, names: nil)
      Authorization.authorize!(actor, "execution.start")
      root = ticket.project.root_path
      repo = Git::Repository.new(root)
      head = repo.head_sha
      execution = Execution.create!(ticket: ticket, provider_key: "local", action: "verify", status: "verifying",
                                    attempt: Execution.next_attempt_for(ticket), base_sha: head, head_sha: head,
                                    worktree_path: root, started_at: Time.current,
                                    metadata: { "requested_by" => actor.label, "dirty" => !repo.clean? })
      EventStore.append!(type: "verification.requested", aggregate: execution, ticket: ticket, execution: execution, actor: actor,
                         payload: { head_sha: head, dirty: !repo.clean? })
      results = run_catalog!(execution: execution, chdir: root, names: names)
      required_ok = results.select(&:required).all?(&:passed?)
      Executions.transition!(execution, required_ok ? "completed" : "failed", failure_code: (required_ok ? nil : "verification_failed"))
      results
    end

    def write_log(execution, name, output)
      dir = Agentboard.config.root_path.join(".agentboard", "logs", execution.id)
      FileUtils.mkdir_p(dir, mode: 0o700)
      path = dir.join("verify-#{name}.log")
      File.write(path, output.to_s)
      Artifact.create!(ticket: execution.ticket, execution: execution, kind: "test_report", uri: "file:#{path}",
                       title: "#{name} output", sha256: Digest::SHA256.hexdigest(output.to_s), provenance: "confirmed",
                       metadata: { name: name })
    rescue SystemCallError
      nil
    end
  end
end
