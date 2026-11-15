module Agentboard
  # Approval requests bound to an exact action digest and code state (spec §28.5, AT-10).
  module Approvals
    DEFAULT_TTL = 72.hours

    module_function

    def request!(project:, action_kind:, actor:, action_payload: {}, reason: nil, ticket: nil, execution: nil,
                 head_sha: nil, workflow_step: nil, required_role: "maintainer", ttl: DEFAULT_TTL, action_digest: nil)
      Authorization.authorize!(actor, "approval.request")
      digest = action_digest || Ids.canonical_digest(action_payload.to_h.merge(action_kind: action_kind, head_sha: head_sha, ticket_id: ticket&.id))
      Approval.transaction do
        existing = Approval.pending.find_by(project_id: project.id, ticket_id: ticket&.id, action_kind: action_kind, action_digest: digest)
        return existing if existing && !existing.expired?

        approval = Approval.create!(
          project: project, ticket_id: ticket&.id, execution: execution, workflow_step_id: workflow_step&.id,
          action_kind: action_kind, action_digest: digest, head_sha: head_sha, action_payload: Redactor.redact_value(action_payload.to_h),
          reason: reason, required_role: required_role, requested_by: actor.label, expires_at: Time.current + ttl
        )
        EventStore.append!(type: "approval.requested", aggregate: approval, project: project, ticket: ticket, execution: execution, actor: actor,
                           payload: { approval_id: approval.id, action_kind: action_kind, head_sha: head_sha, reason: reason })
        approval
      end
    end

    def request_review!(ticket:, actor:, head_sha:, summary: nil)
      request!(project: ticket.project, ticket: ticket, actor: actor, action_kind: "review_completion", head_sha: head_sha,
               action_digest: CompletionPolicy.review_action_digest(ticket, head_sha),
               action_payload: { summary: summary.to_s.truncate(2000) }, reason: summary)
    end

    def decide!(approval:, actor:, decision:, reason: nil)
      raise Error.forbidden("Only humans can decide approvals") unless actor.human?
      Authorization.authorize!(actor, "approval.decide")
      unless Authorization::ROLES.index(actor.role.to_s).to_i >= Authorization::ROLES.index(approval.required_role).to_i
        raise Error.forbidden("Approval requires role #{approval.required_role}")
      end
      raise Error.validation_failed("Decision must be approved or rejected") unless %w[approved rejected].include?(decision)

      Extensions.run(:before_approval_decision, approval: approval, actor: actor)

      Approval.transaction do
        approval.lock!
        raise Error.invalid_transition("Approval is already #{approval.decision}") unless approval.pending?
        if approval.expired?
          approval.update!(decision: "expired")
          raise Error.approval_required("Approval request expired; request a new one")
        end
        if approval.action_kind == "review_completion" && approval.ticket && approval.head_sha != Evidence.head_sha(approval.ticket)
          approval.update!(decision: "invalidated", decision_reason: "head changed before decision")
          raise Error.approval_required("Code changed since the review was requested; a new review is required")
        end

        approval.update!(decision: decision, decided_by: actor.label, decision_reason: reason, decided_at: Time.current)
        EventStore.append!(type: "approval.#{decision}", aggregate: approval, project: approval.project, ticket: approval.ticket,
                           actor: actor, payload: { approval_id: approval.id, action_kind: approval.action_kind, reason: reason })
        approval
      end
    end

    # Any relevant code change invalidates approvals bound to the old head (AT: "Agent edits code after approval").
    def invalidate_stale!(ticket:, head_sha:)
      stale = Approval.where(ticket_id: ticket.id, decision: %w[pending approved]).where.not(head_sha: [ nil, head_sha ])
      stale.find_each do |approval|
        approval.update!(decision: "invalidated", decision_reason: "head moved to #{head_sha.to_s[0, 10]}")
        EventStore.append!(type: "approval.invalidated", aggregate: approval, project: approval.project, ticket: ticket,
                           actor: Authorization.system_actor, payload: { approval_id: approval.id, new_head_sha: head_sha })
      end
    end

    def expire_due!
      Approval.pending.where("expires_at <= ?", Time.current).update_all(decision: "expired", updated_at: Time.current)
    end
  end
end
