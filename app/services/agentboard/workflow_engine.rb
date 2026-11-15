module Agentboard
  # DAG scheduler with precise semantics (spec §28):
  # - a step is runnable when all dependencies succeeded and its condition is true
  # - failed/skipped dependencies skip downstream steps unless the step has an explicit
  #   condition (a failure branch) that evaluates true
  # - bounded retries with backoff create new attempt rows; non-idempotent steps never retry
  # - cancellation propagates to running executions, then finalizes the run
  module WorkflowEngine
    module_function

    def workflow_dir = Agentboard.config.root_path.join(".agentboard", "workflows")

    # Registers (or reuses) an immutable version of a workflow definition.
    def register!(project:, yaml:, actor: Authorization.system_actor)
      Authorization.authorize!(actor, "workflow.manage")
      definition = Workflows::Definition.parse_yaml(yaml, enforce_features: true)
      digest = definition.digest
      existing = WorkflowDefinition.where(project: project, name: definition.name).order(version: :desc).first
      return existing if existing&.digest == digest

      WorkflowDefinition.create!(project: project, name: definition.name, version: (existing&.version || 0) + 1,
                                 definition: definition.to_h, source_yaml: yaml.to_s[0, 100_000], digest: digest)
    end

    def sync_from_disk!(project:)
      Dir[workflow_dir.join("*.yml").to_s].sort.map do |path|
        register!(project: project, yaml: File.read(path))
      rescue Agentboard::Error => e
        Agentboard.logger.warn("[agentboard] workflow #{File.basename(path)} invalid: #{e.message}")
        nil
      end.compact
    end

    def latest(project:, name:)
      WorkflowDefinition.where(project: project, name: name).order(version: :desc).first or
        raise Error.not_found("Workflow #{name} is not registered")
    end

    def start!(definition:, ticket:, actor:)
      Authorization.authorize!(actor, "execution.start")
      # Re-checked at start: a licence may have lapsed since the definition was registered.
      Agentboard.require_feature!(:advanced_workflows) if definition.parsed.advanced_features.any?
      raise Error.workspace_conflict("#{ticket.key} already has an active workflow run") if ticket.workflow_runs.active.exists?

      parsed = definition.parsed
      WorkflowRun.transaction do
        run = WorkflowRun.create!(workflow_definition: definition, ticket: ticket, status: "running", started_at: Time.current,
                                  base_sha: ticket.project.repository.head_sha)
        parsed.steps.each do |s|
          run.steps.create!(step_key: s.id, step_type: s.type, status: "pending", attempt: 1, input: { "depends_on" => s.depends_on })
        end
        EventStore.append!(type: "workflow.started", aggregate: run, ticket: ticket, actor: actor,
                           payload: { workflow: definition.name, version: definition.version, digest: definition.digest, run_id: run.id })
        run
      end
    end

    def cancel!(run:, actor:, reason: "cancelled")
      WorkflowRun.transaction do
        run.lock!
        return run if run.terminal?

        run.update!(status: "cancelled", cancel_reason: reason, finished_at: Time.current)
        run.steps.where(status: %w[pending waiting running]).find_each do |step|
          step.executions.active.each { |e| Executions.request_cancel!(execution: e, actor: actor, reason: "workflow cancelled") }
          step.update!(status: "cancelled", finished_at: Time.current)
        end
        EventStore.append!(type: "workflow.cancelled", aggregate: run, ticket: run.ticket, actor: actor, payload: { reason: reason })
      end
      run
    end

    def tick
      WorkflowRun.where(status: %w[running waiting_for_approval]).find_each { |run| advance(run) }
    end

    def advance(run)
      definition = run.definition
      if definition.timeout_seconds && run.started_at && Time.current - run.started_at > definition.timeout_seconds
        return cancel!(run: run, actor: Authorization.system_actor, reason: "workflow timeout")
      end

      steps = run.current_steps
      steps.each_value { |step| poll_waiting(run, step, definition) if step.status == "waiting" }
      Extensions.run(:workflow_advance, run: run, steps: steps, definition: definition)
      steps = run.reload.current_steps

      definition.topological_order.each do |key|
        step = steps[key]
        next unless step&.status == "pending"
        next if step.available_at && step.available_at > Time.current

        spec = definition.step(key)
        deps = spec.depends_on.map { |d| steps[d] }
        next unless deps.all?(&:terminal?)

        ctx = condition_context(run, steps)
        all_ok = deps.all? { |d| d.status == "succeeded" }
        runnable =
          if spec.condition
            Workflows::Condition.parse(spec.condition).evaluate(ctx)
          else
            all_ok
          end
        if runnable
          start_step(run, step, spec, deps)
        else
          step.update!(status: "skipped", finished_at: Time.current, output: { "reason" => spec.condition ? "condition false" : "dependency did not succeed" })
          EventStore.append!(type: "workflow.step_skipped", aggregate: run, ticket: run.ticket, payload: { step: key })
        end
      end
      finalize(run.reload)
    rescue StandardError => e
      Agentboard.logger.error("[agentboard] workflow #{run.id} advance failed: #{e.class}: #{e.message}")
    end

    def condition_context(run, steps)
      {
        "steps" => steps.transform_values { |s| { "status" => s.status, "output" => s.output } },
        "ticket" => { "priority" => run.ticket.priority, "kind" => run.ticket.kind, "status" => run.ticket.status }
      }
    end

    def start_step(run, step, spec, deps)
      handoff = latest_handoff(deps)
      verify_handoff!(run, handoff) if handoff
      step.update!(status: "running", started_at: Time.current, input: step.input.merge("handoff" => handoff).compact)
      EventStore.append!(type: "workflow.step_started", aggregate: run, ticket: run.ticket, payload: { step: spec.id, type: spec.type, attempt: step.attempt })

      case spec.type
      when "agent"
        Executions.enqueue!(ticket: run.ticket.reload, provider_key: spec.provider, action: spec.action, actor: Authorization.system_actor,
                            workflow_step: step, idempotency_key: "wf:#{step.id}",
                            metadata: { "handoff" => handoff, "base_ref" => handoff&.dig("head_sha"), "workflow_run_id" => run.id,
                                        "timeout_seconds" => spec.timeout_seconds }.compact)
      when "command", "verification"
        run_command_step(run, step, spec, handoff)
      when "human_approval"
        head = handoff&.dig("head_sha") || run.base_sha
        approval = Approvals.request!(project: run.ticket.project, ticket: run.ticket, actor: Authorization.system_actor,
                                      action_kind: "workflow_gate", head_sha: head, workflow_step: step,
                                      required_role: spec.required_role || "maintainer",
                                      action_payload: { workflow_run_id: run.id, step: spec.id, head_sha: head },
                                      reason: "Workflow #{run.workflow_definition.name} requires approval at step #{spec.id}")
        step.update!(status: "waiting", output: { "approval_id" => approval.id, "head_sha" => head })
        run.update!(status: "waiting_for_approval")
      when "condition"
        finish_step(run, step, "succeeded", output: { "result" => true })

      when "git_commit"
        path = handoff&.dig("worktree_path")
        raise Error.validation_failed("git_commit needs a worktree from a previous step") unless path

        manager = Git::WorktreeManager.new(repository: run.ticket.project.repository, workspace: Agentboard.config.workspace_path)
        head = manager.snapshot!(path, message: "#{run.ticket.key}: workflow commit")
        finish_step(run, step, "succeeded", output: (handoff || {}).merge("head_sha" => head))
      else
        handler = Extensions.step_handler(spec.type)
        unless handler
          return finish_step(run, step, "failed", error: "Step type #{spec.type} requires AgentBoard Pro", failure_code: "capability_unavailable")
        end

        handler.call(run: run, step: step, spec: spec, handoff: handoff)
      end
    rescue Agentboard::Error => e
      finish_step(run, step, "failed", error: e.message, failure_code: e.code.downcase)
    end



    def latest_handoff(deps)
      deps.select { |d| d.status == "succeeded" && d.output["head_sha"] }.max_by { |d| d.finished_at.to_f }&.output
    end

    # The receiving step verifies actual repository state rather than trusting the summary.
    def verify_handoff!(run, handoff)
      repo = run.ticket.project.repository
      if handoff["head_sha"] && repo.resolve_commit(handoff["head_sha"]).nil?
        raise Error.validation_failed("Handoff head #{handoff["head_sha"]} does not exist in the repository")
      end
      ids = Array(handoff["artifact_ids"])
      if ids.any? && Artifact.where(id: ids, ticket_id: run.ticket_id).count != ids.size
        raise Error.validation_failed("Handoff references unknown artifacts")
      end
    end

    def run_command_step(run, step, spec, handoff)
      dir = handoff&.dig("worktree_path").presence || run.ticket.project.root_path
      PathGuard.within!(Agentboard.config.workspace_path, dir) if handoff&.dig("worktree_path").present?
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          execution = Execution.create!(ticket: run.ticket, provider_key: "local", action: "verify", status: "verifying",
                                        attempt: Execution.next_attempt_for(run.ticket), workflow_step: step, worktree_path: dir,
                                        base_sha: handoff&.dig("base_sha"), head_sha: Git::Repository.new(dir).head_sha(chdir: dir),
                                        started_at: Time.current, metadata: { "command" => spec.command })
          results = VerificationService.run_catalog!(execution: execution, chdir: dir, names: [ spec.command ], timeout: spec.timeout_seconds)
          ok = results.all?(&:passed?)
          Executions.transition!(execution, ok ? "completed" : "failed", failure_code: ok ? nil : "verification_failed")
        end
      rescue StandardError => e
        Agentboard.logger.error("[agentboard] command step failed: #{e.class}: #{e.message}")
        ActiveRecord::Base.connection_pool.with_connection { finish_step(run, step.reload, "failed", error: e.class.name) }
      end
    end

    # Callback from Executions.transition! when an execution linked to a step finishes.
    def step_execution_finished(execution)
      step = execution.workflow_step
      return unless step && step.status == "running"

      run = step.workflow_run
      ok = execution.status == "completed"
      output = {
        "schema_version" => 1, "ticket_key" => run.ticket.key, "from_step" => step.step_key,
        "base_sha" => execution.base_sha, "head_sha" => execution.head_sha, "branch" => execution.branch,
        "worktree_path" => execution.worktree_path, "execution_id" => execution.id,
        "artifact_ids" => execution.artifacts.where(kind: %w[commit diff test_report]).pluck(:id),
        "verification_result_ids" => execution.verification_results.pluck(:id),
        "summary" => execution.summary.to_s[0, 2000], "known_issues" => ok ? [] : [ execution.failure_message ].compact
      }
      finish_step(run, step, ok ? "succeeded" : "failed", output: output, error: execution.failure_message,
                                                          failure_code: execution.failure_code)
    end

    def poll_waiting(run, step, definition)
      approval = Approval.find_by(id: step.output["approval_id"])
      return finish_step(run, step, "failed", error: "approval missing") unless approval

      head = step.output["head_sha"]
      digest = approval.action_digest
      if approval.valid_for?(action_digest: digest, head_sha: head)
        finish_step(run, step, "succeeded", output: step.output.merge("approved_by" => approval.decided_by))
      elsif %w[rejected expired invalidated].include?(approval.decision) || approval.expired?
        finish_step(run, step, "failed", error: "approval #{approval.decision}")
      end
    end

    def finish_step(run, step, status, output: nil, error: nil, failure_code: nil)
      WorkflowStep.transaction do
        step.update!(status: status, finished_at: Time.current, output: output || step.output, error: error&.to_s&.[](0, 2000))
        EventStore.append!(type: "workflow.step_#{status}", aggregate: run, ticket: run.ticket,
                           payload: { step: step.step_key, attempt: step.attempt, error: error }.compact)
        run.update!(status: "running") if run.status == "waiting_for_approval" && run.steps.where(status: "waiting").none?
        Extensions.run(:workflow_step_failed, run: run, step: step, failure_code: failure_code) if status == "failed"
      end
    end


    def finalize(run)
      return if run.terminal?

      steps = run.current_steps.values
      return unless steps.all?(&:terminal?)

      status = steps.any? { |s| s.status == "failed" } ? "failed" : "succeeded"
      run.update!(status: status, finished_at: Time.current)
      EventStore.append!(type: "workflow.#{status}", aggregate: run, ticket: run.ticket, payload: { run_id: run.id })
    end

  end
end
