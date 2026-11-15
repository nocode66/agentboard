module Agentboard
  # Lightweight change feed for live updates without ActionCable: clients poll the latest
  # event cursor and morph-refresh the page when it moves.
  class PulseController < ApplicationController
    def show
      latest = Event.where(project_id: [ current_project.id, nil ]).order(received_at: :desc, id: :desc).pick(:id, :received_at)
      active = Execution.active.joins(:ticket).where(agentboard_tickets: { project_id: current_project.id }).count
      render json: { cursor: latest&.first, at: latest&.last&.utc&.iso8601(3), active_executions: active,
                     pending_approvals: pending_approvals_count }
    end
  end
end
