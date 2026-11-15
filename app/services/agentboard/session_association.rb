module Agentboard
  # Associates an agent session with (at most) one active ticket (spec §7).
  # Precedence: MCP selection > CLI attach > dashboard > branch heuristic > provider metadata.
  # An automatic association never replaces an explicit human choice.
  module SessionAssociation
    module_function

    def link!(session:, ticket:, source:, actor:, confidence: "confirmed")
      raise Error.validation_failed("Unknown association source") unless SessionTicketLink::SOURCES.key?(source)

      SessionTicketLink.transaction do
        current = session.ticket_links.active.lock.first
        if current
          return current if current.ticket_id == ticket.id && current.precedence <= SessionTicketLink::SOURCES[source]
          if current.explicit? && !SessionTicketLink::EXPLICIT.include?(source)
            raise Error.policy_denied("Session is explicitly attached to #{current.ticket.key}; automatic association ignored")
          end

          current.update!(ended_at: Time.current)
        end
        link = session.ticket_links.create!(ticket: ticket, source: source, confidence: confidence, started_at: Time.current)
        EventStore.append!(type: "agent.session.attached", aggregate: session, project: session.project, ticket: ticket, session: session,
                           actor: actor, provenance: (source == "branch_heuristic" ? "inferred" : "confirmed"),
                           payload: { ticket_key: ticket.key, source: source, confidence: confidence, previous_ticket_id: current&.ticket_id })
        link
      end
    end

    def unlink!(session:, actor:)
      link = session.ticket_links.active.first
      return unless link

      link.update!(ended_at: Time.current)
      EventStore.append!(type: "agent.session.detached", aggregate: session, project: session.project, ticket: link.ticket,
                         session: session, actor: actor, payload: { ticket_key: link.ticket.key })
    end

    # Branch heuristic: `agentboard/AB-142/...`, `feature/AB-142-foo`, etc. Requires confirmation.
    def ticket_from_branch(branch, project:)
      match = branch.to_s.match(/(?:\A|[\/_-])(#{Regexp.escape(project.key)}-\d+)(?:\z|[\/_-])/i)
      match && Ticket.find_by_key(match[1].upcase, project: project)
    end
  end
end
