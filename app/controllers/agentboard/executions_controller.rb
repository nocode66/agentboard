module Agentboard
  class ExecutionsController < ApplicationController
    before_action :load_execution, except: :index

    def index
      @status = params[:status].presence
      scope = Execution.joins(:ticket).where(agentboard_tickets: { project_id: current_project.id }).includes(:ticket, :verification_results).recent
      scope = scope.where(status: @status) if @status
      @executions = scope.limit(200)
      @daemon = Runtime::DaemonControl.status
    end

    def show
      @events = Event.where(execution_id: @execution.id).order(:received_at, :id).last(400)
      @results = @execution.verification_results
      @usage = @execution.usage_records
      @artifacts = @execution.artifacts.order(:created_at)
      @daemon = Runtime::DaemonControl.status
      @pending_approvals = Approval.pending.where(execution_id: @execution.id).order(:created_at)
    end

    def cancel
      Executions.request_cancel!(execution: @execution, actor: current_actor, reason: params[:reason].presence || "cancelled from dashboard")
      redirect_to execution_path(@execution), notice: "Cancellation requested", status: :see_other
    end

    def retry
      execution = Executions.retry!(execution: @execution, actor: current_actor)
      redirect_to execution_path(execution), notice: "Retry queued as attempt #{execution.attempt}", status: :see_other
    end

    def resume
      execution = Executions.resume!(execution: @execution, actor: current_actor, message: params[:message].presence || "Continue the task.")
      redirect_to execution_path(execution), notice: "Resuming the provider session as attempt #{execution.attempt}", status: :see_other
    end

    # Redacted log tail for the console (polled).
    def log
      render plain: Redactor.redact(@execution.log_tail(bytes: 48 * 1024)), content_type: "text/plain"
    end

    private

    def load_execution
      @execution = Execution.joins(:ticket).where(agentboard_tickets: { project_id: current_project.id }).find(params[:id])
    end
  end
end
