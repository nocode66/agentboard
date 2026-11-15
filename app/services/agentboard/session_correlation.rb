module Agentboard
  # Links sessions that belong to the same agent process (see ProcessAncestry). A hook
  # session corroborates an MCP session and vice versa; links propagate ticket context.
  module SessionCorrelation
    module_function

    def record_agent!(session, agent)
      return unless agent

      session.update_columns(metadata: session.metadata.merge(agent.to_h))
      correlate!(session)
    end

    def peers(session)
      pid = session.metadata["agent_pid"]
      fp = session.metadata["agent_fingerprint"]
      return AgentSession.none unless pid && fp

      AgentSession.where(project_id: session.project_id, state: "active").where.not(id: session.id).select do |s|
        s.metadata["agent_pid"] == pid && s.metadata["agent_fingerprint"] == fp
      end
    end

    def correlate!(session)
      peers(session).each do |peer|
        next if peer.metadata["correlated_session_id"] == session.id

        peer.update_columns(metadata: peer.metadata.merge("correlated_session_id" => session.id))
        session.update_columns(metadata: session.metadata.merge("correlated_session_id" => peer.id))
        EventStore.append!(type: "agent.session.correlated", aggregate: session, project: session.project, session: session,
                           payload: { peer_session_id: peer.id, peer_trust: peer.trust_level, agent_pid: session.metadata["agent_pid"] })
        # Propagate an explicit ticket link to the peer that has none.
        [ [ peer, session ], [ session, peer ] ].each do |src, dst|
          link = src.active_link
          next unless link&.explicit? && dst.active_link.nil?

          SessionAssociation.link!(session: dst, ticket: link.ticket, source: link.source == "runtime" ? "runtime" : "mcp",
                                   actor: Authorization.system_actor)
        end
      end
    end

    # After an explicit MCP link, pull the correlated hook session along.
    def propagate_link!(session)
      peer_id = session.metadata["correlated_session_id"]
      peer = peer_id && AgentSession.find_by(id: peer_id, state: "active")
      link = session.active_link
      return unless peer && link
      return if peer.active_link&.ticket_id == link.ticket_id

      SessionAssociation.link!(session: peer, ticket: link.ticket, source: "mcp", actor: Authorization.system_actor)
    rescue Agentboard::Error
      nil
    end
  end
end
