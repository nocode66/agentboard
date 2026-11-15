module Agentboard
  # Ticket domain operations. Every mutation: authorizes the actor, uses optimistic
  # locking, emits an event in the same transaction, and never trusts agent claims.
  module Tickets
    module_function

    def create!(project:, actor:, title:, description: "", kind: "task", priority: 2, criteria: [], labels: [],
                parent: nil, milestone: nil, status: "backlog", correlation_id: nil)
      Authorization.authorize!(actor, "ticket.write")
      raise Error.validation_failed("New tickets start in backlog or ready") unless %w[backlog ready].include?(status)

      Ticket.transaction do
        number = project.next_ticket_number!
        ticket = project.tickets.create!(
          number: number, title: title.to_s.strip, description: description.to_s, kind: kind, priority: priority.to_i,
          labels: Array(labels).map(&:to_s).reject(&:blank?).uniq, parent: parent, milestone: milestone,
          created_by_id: actor.id, status: "backlog", position: Time.current.to_f
        )
        Array(criteria).map(&:to_s).map(&:strip).reject(&:blank?).each do |text|
          ticket.acceptance_criteria.create!(description: text)
        end
        EventStore.append!(type: "ticket.created", aggregate: ticket, ticket: ticket, actor: actor, correlation_id: correlation_id,
                           payload: { key: ticket.key, title: ticket.title, kind: kind, priority: ticket.priority })
        transition!(ticket: ticket, to: "ready", actor: actor) if status == "ready"
        ticket
      end
    end

    def update!(ticket:, actor:, attributes:, expected_version: nil, correlation_id: nil)
      Authorization.authorize!(actor, "ticket.write")
      allowed = attributes.to_h.symbolize_keys.slice(:title, :description, :kind, :priority, :labels, :milestone_id, :parent_id, :assignee_profile_id)
      allowed[:milestone_id] = allowed[:milestone_id].presence if allowed.key?(:milestone_id)
      if allowed[:milestone_id] && !ticket.project.milestones.exists?(allowed[:milestone_id])
        raise Error.validation_failed("Milestone belongs to another project")
      end
      allowed[:labels] = Array(allowed[:labels]).flat_map { |l| l.to_s.split(",") }.map(&:strip).reject(&:blank?).uniq if allowed.key?(:labels)
      Ticket.transaction do
        ticket.lock_version = expected_version.to_i if expected_version
        before = ticket.attributes.slice(*allowed.keys.map(&:to_s))
        ticket.update!(allowed)
        changes = ticket.saved_changes.except("updated_at", "lock_version")
        if changes.any?
          EventStore.append!(type: "ticket.updated", aggregate: ticket, ticket: ticket, actor: actor, correlation_id: correlation_id,
                             payload: { changes: changes.transform_values { |(a, b)| { from: a, to: b } }, before: before.keys })
        end
        ticket
      end
    end

    # Moves a ticket through the state machine (spec §24.1) enforcing guards.
    #
    # options:
    #   reason:          required for blocked / cancelled / reopened / criteria override
    #   lease_token:     required when an agent actor mutates a claimed ticket
    #   session:         trusted AgentSession for agent actors
    #   override_criteria: human-only, backlog -> ready without criteria
    #   verification_requested: in_progress -> testing without an implementation artifact
    #   head_sha:        commit under review for testing -> review
    def transition!(ticket:, to:, actor:, reason: nil, lease_token: nil, session: nil, expected_version: nil,
                    override_criteria: false, verification_requested: false, head_sha: nil, correlation_id: nil)
      to = to.to_s
      Authorization.authorize!(actor, permission_for(to))
      if actor.agent? && Authorization::HUMAN_ONLY_TRANSITIONS.include?(to)
        raise Error.forbidden("Agents cannot move tickets to #{to}; a human must do this")
      end

      # ready -> claimed always goes through the lease service.
      if to == "claimed"
        claim = LeaseService.claim!(ticket: ticket, actor: actor, session: session, expected_version: expected_version, correlation_id: correlation_id)
        return ticket.reload.tap { |t| t.instance_variable_set(:@issued_lease, claim) }
      end

      Ticket.transaction do
        ticket.lock!
        if expected_version && ticket.lock_version != expected_version.to_i
          raise Error.version_conflict("Ticket #{ticket.key} changed (version #{ticket.lock_version})", current_version: ticket.lock_version)
        end
        from = ticket.status
        return ticket if from == to

        StateMachines::Ticket.assert!(from, to)
        lease = enforce_lease!(ticket, actor, lease_token, session)
        guard!(ticket, from, to, actor: actor, reason: reason, override_criteria: override_criteria,
               verification_requested: verification_requested, head_sha: head_sha, lease: lease)

        attrs = { status: to }
        attrs[:blocked_reason] = (to == "blocked" ? reason : nil)
        attrs[:completed_at] = (to == "done" ? Time.current : nil)
        ticket.update!(attrs)

        if %w[ready done cancelled backlog].include?(to)
          LeaseService.release_all!(ticket: ticket, reason: "ticket_#{to}")
        end
        if %w[done cancelled].include?(to)
          SessionTicketLink.active.where(ticket_id: ticket.id).update_all(ended_at: Time.current, updated_at: Time.current)
        end

        EventStore.append!(type: "ticket.transitioned", aggregate: ticket, ticket: ticket, actor: actor, session: session,
                           correlation_id: correlation_id,
                           payload: { from: from, to: to, reason: reason, head_sha: head_sha, override_criteria: override_criteria.presence }.compact)
        ticket
      end
    end

    def permission_for(to)
      case to
      when "done" then "ticket.transition" # gated by CompletionPolicy
      when "reopened" then "ticket.reopen"
      when "cancelled" then "ticket.cancel"
      when "claimed" then "ticket.claim"
      else "ticket.transition"
      end
    end

    def enforce_lease!(ticket, actor, token, session)
      live = ticket.leases.live.where("expires_at > ?", Time.current).first
      if actor.agent?
        # Agents may only mutate tickets they hold a valid, current lease for.
        return LeaseService.validate!(ticket: ticket, token: token, session: session)
      end
      live
    end

    def guard!(ticket, from, to, actor:, reason:, override_criteria:, verification_requested:, head_sha:, lease:)
      case [ from, to ]
      in [ "backlog", "ready" ]
        if ticket.acceptance_criteria.none?
          unless override_criteria && actor.human? && reason.present?
            raise Error.policy_denied("Add acceptance criteria before marking #{ticket.key} ready (or override with a reason)")
          end
        end
      in [ "claimed", "in_progress" ]
        if actor.agent?
          link = SessionTicketLink.active.find_by(ticket_id: ticket.id, agent_session_id: lease&.agent_session_id)
          raise Error.policy_denied("Session must be bound to the ticket (start_work) before work begins") unless link
        elsif lease.nil?
          raise Error.policy_denied("#{ticket.key} has no active lease; claim it first")
        end
      in [ "in_progress", "testing" ]
        has_impl = ticket.artifacts.where(kind: %w[commit diff pull_request]).exists? || ticket.executions.where.not(head_sha: nil).exists?
        unless has_impl || verification_requested
          raise Error.policy_denied("Attach an implementation artifact (commit/diff) or explicitly request verification")
        end
      in [ "testing", "review" ]
        report = CompletionPolicy.checks_report(ticket, head_sha: head_sha || Evidence.head_sha(ticket))
        raise Error.policy_denied("Required checks have not passed for the current head: #{report[:missing].join("; ")}", **report) unless report[:ok]
      in [ "review", "done" ]
        report = CompletionPolicy.evaluate(ticket, actor: actor)
        raise Error.policy_denied("Completion policy not satisfied: #{report[:missing].join("; ")}", missing: report[:missing]) unless report[:ok]
      in [ _, "blocked" ]
        raise Error.validation_failed("A blocker reason is required") if reason.blank?
      in [ "blocked", "ready" ]
        raise Error.policy_denied("Dependencies are not finished: #{ticket.unsatisfied_dependencies.map(&:key).join(", ")}") unless ticket.dependencies_satisfied?
      in [ "done", "reopened" ] | [ _, "cancelled" ]
        raise Error.validation_failed("A reason is required") if reason.blank?
      else
        nil
      end
    end

    def add_comment!(ticket:, actor:, body:, visibility: "team", correlation_id: nil)
      Authorization.authorize!(actor, "ticket.comment")
      redacted, count = Redactor.redact_with_count(body.to_s)
      Comment.transaction do
        comment = ticket.comments.create!(body: redacted, actor_type: actor.type, actor_id: actor.id, actor_name: actor.label, visibility: visibility)
        EventStore.append!(type: "ticket.commented", aggregate: ticket, ticket: ticket, actor: actor, correlation_id: correlation_id,
                           payload: { comment_id: comment.id, excerpt: redacted.truncate(160) })
        if count.positive?
          EventStore.append!(type: "security.secret_redacted", aggregate: ticket, ticket: ticket, actor: actor,
                             payload: { where: "comment", redactions: count })
        end
        comment
      end
    end

    def add_criterion!(ticket:, actor:, description:, verification_kind: "manual")
      Authorization.authorize!(actor, "ticket.write")
      AcceptanceCriterion.transaction do
        c = ticket.acceptance_criteria.create!(description: description, verification_kind: verification_kind)
        EventStore.append!(type: "ticket.criterion_added", aggregate: ticket, ticket: ticket, actor: actor, payload: { criterion_id: c.id, description: description })
        c
      end
    end

    # Humans verify/waive criteria; agents may only *propose* via comments.
    def set_criterion_state!(criterion:, actor:, state:, evidence_id: nil)
      raise Error.forbidden("Only humans can verify acceptance criteria") unless actor.human? || actor.system?
      Authorization.authorize!(actor, "ticket.write")
      raise Error.validation_failed("Unknown criterion state") unless AcceptanceCriterion::STATES.include?(state)

      ticket = criterion.ticket
      if evidence_id.present? && !Artifact.where(id: evidence_id, ticket_id: ticket.id).exists? && !VerificationResult.where(id: evidence_id).exists?
        raise Error.validation_failed("Evidence #{evidence_id} is not linked to #{ticket.key}")
      end
      AcceptanceCriterion.transaction do
        criterion.update!(state: state, evidence_id: evidence_id, verified_by: actor.label, verified_at: (state == "pending" ? nil : Time.current))
        EventStore.append!(type: "ticket.criterion_#{state}", aggregate: ticket, ticket: ticket, actor: actor,
                           payload: { criterion_id: criterion.id, evidence_id: evidence_id })
        criterion
      end
    end

    def add_dependency!(ticket:, depends_on:, actor:, kind: "blocks")
      Authorization.authorize!(actor, "ticket.write")
      TicketDependency.transaction do
        dep = ticket.dependencies.create!(depends_on_ticket: depends_on, kind: kind)
        EventStore.append!(type: "ticket.dependency_added", aggregate: ticket, ticket: ticket, actor: actor,
                           payload: { depends_on: depends_on.key, kind: kind })
        dep
      end
    end

    def reorder!(ticket:, actor:, position:)
      Authorization.authorize!(actor, "ticket.write")
      ticket.update_columns(position: position.to_f, updated_at: Time.current)
    end
  end
end
