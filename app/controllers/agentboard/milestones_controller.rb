module Agentboard
  class MilestonesController < ApplicationController
    def index
      @milestones = current_project.milestones.order(Arel.sql("CASE WHEN status = 'open' THEN 0 ELSE 1 END"), :target_date, :name)
      @progress = Ticket.where(milestone_id: @milestones.map(&:id)).group(:milestone_id, :status).count
    end

    def create
      Authorization.authorize!(current_actor, "ticket.write")
      p = params.require(:milestone).permit(:name, :target_date)
      m = current_project.milestones.create!(name: p[:name], target_date: p[:target_date].presence)
      EventStore.append!(type: "milestone.created", aggregate: m, project: current_project, actor: current_actor, payload: { name: m.name, target_date: m.target_date })
      redirect_to milestones_path, notice: "Milestone created", status: :see_other
    end

    def update
      Authorization.authorize!(current_actor, "ticket.write")
      m = current_project.milestones.find(params[:id])
      m.update!(status: params.require(:status).presence_in(%w[open closed]) || m.status)
      redirect_to milestones_path, status: :see_other
    end
  end
end
