module Agentboard
  # Evidence-based completion (spec §15, §29.4). Agents may *request* completion but every
  # gate is evaluated against persisted records — never against agent-supplied JSON.
  module CompletionPolicy
    module_function

    def settings = Agentboard.config.completion

    # require_merged_pr: "when_linked" (default) | "always" | "never" (true/false accepted).
    # "when_linked": a ticket with an open or merged PR must have that PR merged on the
    # reviewed head; tickets without a PR (or only abandoned ones) complete on other evidence.
    def merged_pr_mode
      case settings["require_merged_pr"]
      when true, "always" then "always"
      when false, nil, "never" then "never"
      else "when_linked"
      end
    end

    def merged_pr_required?(ticket)
      case merged_pr_mode
      when "always" then true
      when "never" then false
      else ticket.artifacts.where(kind: "pull_request").any? { |a| %w[open merged].include?(a.metadata["state"]) }
      end
    end

    # Required checks must have passed for exactly `head_sha` (AT-08).
    def checks_report(ticket, head_sha:)
      missing = []
      required = Agentboard.config.verification_catalog.required_names
      if head_sha.blank?
        missing << "no verified head commit is linked to the ticket"
        return { ok: false, head_sha: nil, missing: missing, checks: [] }
      end

      checks = required.map do |name|
        result = VerificationResult.where(ticket_id: ticket.id, name: name).order(started_at: :desc).first
        latest_for_head = VerificationResult.where(ticket_id: ticket.id, name: name, commit_sha: head_sha).order(started_at: :desc).first
        status =
          if latest_for_head&.passed? then "passed"
          elsif latest_for_head then latest_for_head.status
          elsif result then "stale"
          else "missing"
          end
        missing << "#{name} #{status == "stale" ? "passed only for an older commit" : status} at #{head_sha[0, 10]}" unless status == "passed"
        { name: name, status: status, commit_sha: latest_for_head&.commit_sha || result&.commit_sha, result_id: latest_for_head&.id }
      end
      { ok: missing.empty?, head_sha: head_sha, missing: missing, checks: checks }
    end

    def review_action_digest(ticket, head_sha)
      Ids.canonical_digest(action: "review_completion", ticket_id: ticket.id, head_sha: head_sha)
    end

    def evaluate(ticket, actor: nil)
      head = Evidence.head_sha(ticket)
      missing = []
      report = { ticket_key: ticket.key, head_sha: head }

      if settings["require_criteria_verified"]
        crit = ticket.acceptance_criteria.map { |c| { id: c.id, status: c.state, evidence_id: c.evidence_id } }
        unsatisfied = ticket.acceptance_criteria.reject(&:satisfied?)
        missing << "#{unsatisfied.size} acceptance criteria not verified" if unsatisfied.any?
        missing << "ticket has no acceptance criteria" if crit.empty?
        report[:criteria] = crit
      end

      if settings["require_checks"]
        checks = checks_report(ticket, head_sha: head)
        missing.concat(checks[:missing])
        report[:required_checks] = checks[:checks]
      end

      if settings["require_approval"] || Agentboard.config.security["require_review"]
        digest = head && review_action_digest(ticket, head)
        approval = head && Approval.where(ticket_id: ticket.id, action_kind: "review_completion", decision: "approved").order(decided_at: :desc)
                                   .find { |a| a.valid_for?(action_digest: digest, head_sha: head) }
        missing << "human review approval for #{head ? head[0, 10] : "the current head"} is missing" unless approval
        report[:review] = approval ? { status: "approved", approval_id: approval.id } : { status: "pending" }
      end

      if merged_pr_required?(ticket)
        # The merged PR must carry exactly the head that passed checks and review.
        pr = ticket.artifacts.where(kind: "pull_request").find do |a|
          a.metadata["state"] == "merged" && a.metadata["merge_verified"] && head.present? && a.metadata["head_sha"] == head
        end
        missing << "merged pull request (verified by the Git provider) for #{head ? head[0, 10] : "the current head"}" unless pr
        report[:pull_request] = pr ? { state: "merged", merge_commit_sha: pr.metadata["merge_commit_sha"] } : { state: "missing" }
      end

      report.merge(ok: missing.empty?, missing: missing)
    end

    # Policy-controlled completion used by the UI and the MCP `complete_ticket` tool.
    def complete!(ticket:, actor:, expected_version: nil, lease_token: nil, session: nil)
      report = evaluate(ticket, actor: actor)
      raise Error.policy_denied("Completion policy not satisfied", missing: report[:missing]) unless report[:ok]

      if actor.agent?
        # Agents need a valid lease; the human approval gate above has already been met.
        LeaseService.validate!(ticket: ticket, token: lease_token, session: session)
        ticket.transaction do
          ticket.lock!
          StateMachines::Ticket.assert!(ticket.status, "done")
          ticket.update!(status: "done", completed_at: Time.current)
          LeaseService.release_all!(ticket: ticket, reason: "ticket_done")
          EventStore.append!(type: "ticket.transitioned", aggregate: ticket, ticket: ticket, actor: actor, session: session,
                             payload: { from: "review", to: "done", evidence: report.except(:missing, :ok) })
        end
        ticket
      else
        Tickets.transition!(ticket: ticket, to: "done", actor: actor, expected_version: expected_version)
      end
    end
  end
end
