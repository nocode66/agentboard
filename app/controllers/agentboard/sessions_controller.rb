module Agentboard
  # Dashboard association (precedence 3) and confirmation of heuristic links.
  class SessionsController < ApplicationController
    def update
      session_record = AgentSession.where(project_id: current_project.id).find(params[:id])
      if params[:revoke] == "1"
        SessionCredential.revoke!(session_record, actor: current_actor, reason: "revoked from dashboard")
        return redirect_back(fallback_location: agents_path, notice: "Session revoked; its MCP tools now fail with UNAUTHORIZED", status: :see_other)
      end
      if params[:ticket_key].present?
        ticket = Ticket.find_by_key!(params[:ticket_key], project: current_project)
        SessionAssociation.link!(session: session_record, ticket: ticket, source: "dashboard", actor: current_actor)
      else
        SessionAssociation.unlink!(session: session_record, actor: current_actor)
      end
      redirect_back fallback_location: agents_path, status: :see_other
    end
  end
end
