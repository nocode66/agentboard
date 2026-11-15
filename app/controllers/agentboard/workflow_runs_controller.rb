module Agentboard
  class WorkflowRunsController < ApplicationController
    before_action { @run = WorkflowRun.joins(:ticket).where(agentboard_tickets: { project_id: current_project.id }).find(params[:id]) }

    def show
      @definition = @run.definition
      @steps = @run.current_steps
      @all_steps = @run.steps.includes(:executions).order(:created_at)
    end

    def cancel
      WorkflowEngine.cancel!(run: @run, actor: current_actor, reason: "cancelled from dashboard")
      redirect_to workflow_run_path(@run), status: :see_other
    end
  end
end
