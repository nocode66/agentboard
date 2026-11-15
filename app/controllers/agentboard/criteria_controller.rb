module Agentboard
  class CriteriaController < ApplicationController
    def create
      ticket = find_ticket
      Tickets.add_criterion!(ticket: ticket, actor: current_actor, description: params.require(:criterion).require(:description),
                             verification_kind: params.dig(:criterion, :verification_kind).presence || "manual")
      redirect_to ticket_path(ticket, anchor: "criteria"), status: :see_other
    end

    def update
      ticket = find_ticket
      criterion = ticket.acceptance_criteria.find(params[:id])
      Tickets.set_criterion_state!(criterion: criterion, actor: current_actor, state: params.require(:state), evidence_id: params[:evidence_id].presence)
      redirect_to ticket_path(ticket, anchor: "criteria"), status: :see_other
    end
  end
end
