module Agentboard
  # Retention and deletion (spec §32.3). Ticket and audit metadata are kept; raw logs,
  # provider output events, delivered outbox rows and expired idempotency keys age out.
  # Purging a project is a separate, explicitly confirmed operation.
  module DataGovernance
    PROVIDER_OUTPUT_EVENTS = %w[agent.execution.output agent.execution.message agent.provider.unknown agent.provider.system].freeze

    module_function

    def apply_retention!(project:, dry_run: false, now: Time.current)
      r = Agentboard.config.settings["retention"] || {}
      log_cutoff = now - r.fetch("raw_log_days", 30).to_i.days
      event_cutoff = now - r.fetch("provider_output_event_days", 30).to_i.days
      logs_root = Agentboard.config.root_path.join(".agentboard", "logs")
      old_logs = Dir[logs_root.join("*").to_s].select { |d| File.mtime(d) < log_cutoff }
      events = Event.where(project_id: project.id, event_type: PROVIDER_OUTPUT_EVENTS).where("received_at < ?", event_cutoff)
      outbox = OutboxMessage.where(state: "delivered").where("delivered_at < ?", now - 7.days)
      keys = IdempotencyKey.where("expires_at < ?", now)
      deliveries = WebhookDelivery.where("created_at < ?", now - 90.days)
      report = { log_dirs: old_logs.size, provider_output_events: events.count, delivered_outbox: outbox.count,
                 idempotency_keys: keys.count, webhook_deliveries: deliveries.count, dry_run: dry_run }
      return report if dry_run

      FileUtils.rm_rf(old_logs)
      OutboxMessage.where(event_id: events.select(:id)).delete_all
      events.delete_all
      outbox.delete_all
      keys.delete_all
      deliveries.delete_all
      EventStore.append!(type: "security.retention_applied", aggregate: project, project: project, actor: Authorization.system_actor,
                         payload: report.except(:dry_run))
      report
    end

    # Deletes every AgentBoard record of a project. Requires typing the project key.
    def purge_project!(project:, confirm:, actor:)
      raise Error.forbidden("Only administrators can purge") unless actor.role == "administrator"
      raise Error.validation_failed("Confirmation must equal the project key (#{project.key})") unless confirm.to_s == project.key

      counts = {}
      ActiveRecord::Base.transaction do
        tickets = Ticket.where(project_id: project.id)
        executions = Execution.where(ticket_id: tickets.select(:id))
        runs = WorkflowRun.where(ticket_id: tickets.select(:id))
        steps = WorkflowStep.where(workflow_run_id: runs.select(:id))
        sessions = AgentSession.where(project_id: project.id)
        events = Event.where(project_id: project.id)
        {
          outbox: OutboxMessage.where(event_id: events.select(:id)), events: events,
          usage: UsageRecord.where(execution_id: executions.select(:id)), verification: VerificationResult.where(execution_id: executions.select(:id)),
          approvals: Approval.where(project_id: project.id), artifacts: Artifact.where(ticket_id: tickets.select(:id)),
          executions: executions, steps: steps, runs: runs, workflows: WorkflowDefinition.where(project_id: project.id),
          leases: TicketLease.where(ticket_id: tickets.select(:id)), links: SessionTicketLink.where(agent_session_id: sessions.select(:id)),
          sessions: sessions, profiles: AgentProfile.where(project_id: project.id), comments: Comment.where(ticket_id: tickets.select(:id)),
          criteria: AcceptanceCriterion.where(ticket_id: tickets.select(:id)),
          dependencies: TicketDependency.where(ticket_id: tickets.select(:id)).or(TicketDependency.where(depends_on_ticket_id: tickets.select(:id))),
          snapshots: RepositorySnapshot.where(project_id: project.id)
        }.each { |name, scope| counts[name] = scope.delete_all }
        tickets.update_all(parent_id: nil)
        counts[:tickets] = tickets.delete_all
        counts[:milestones] = Milestone.where(project_id: project.id).delete_all
        project.delete
      end
      Agentboard.logger.warn("[agentboard] project #{project.key} purged by #{actor.label}: #{counts}")
      counts
    end
  end
end
