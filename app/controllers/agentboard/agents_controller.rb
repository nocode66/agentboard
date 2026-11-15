module Agentboard
  class AgentsController < ApplicationController
    def index
      @probes = Providers.registry.all.map { |p| [ p, p.probe ] }
      @sessions = AgentSession.where(project: current_project).order(Arel.sql("COALESCE(last_seen_at, created_at) DESC")).includes(ticket_links: :ticket).limit(50)
      @daemon = Runtime::DaemonControl.status
      @open_tickets = current_project.tickets.open.ordered.limit(200)
    end
  end
end
