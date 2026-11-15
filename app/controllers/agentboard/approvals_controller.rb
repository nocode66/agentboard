module Agentboard
  class ApprovalsController < ApplicationController
    def index
      Approvals.expire_due!
      @pending = Approval.pending.where(project_id: current_project.id).order(:created_at)
      @decided = Approval.where(project_id: current_project.id).where.not(decision: "pending").order(updated_at: :desc).limit(50)
    end

    def update
      approval = Approval.where(project_id: current_project.id).find(params[:id])
      Approvals.decide!(approval: approval, actor: current_actor, decision: params.require(:decision), reason: params[:reason].presence)
      redirect_back fallback_location: approvals_path, notice: "Approval #{params[:decision]}", status: :see_other
    end
  end
end
