module Agentboard
  class DependenciesController < ApplicationController
    def create
      ticket = find_ticket
      other = Ticket.find_by_key!(params.require(:depends_on), project: current_project)
      Tickets.add_dependency!(ticket: ticket, depends_on: other, actor: current_actor)
      redirect_to ticket_path(ticket), notice: "#{ticket.key} now depends on #{other.key}", status: :see_other
    end

    def destroy
      ticket = find_ticket
      Authorization.authorize!(current_actor, "ticket.write")
      dep = ticket.dependencies.find(params[:id])
      dep.destroy!
      EventStore.append!(type: "ticket.dependency_removed", aggregate: ticket, ticket: ticket, actor: current_actor,
                         payload: { depends_on: dep.depends_on_ticket.key })
      redirect_to ticket_path(ticket), status: :see_other
    end
  end
end
