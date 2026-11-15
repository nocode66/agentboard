module Agentboard
  class TicketsController < ApplicationController
    before_action :load_ticket, except: %i[index new create]

    # Backlog: dense, filterable list of every ticket.
    def index
      @status = params[:status].presence
      scope = current_project.tickets.includes(:project, :acceptance_criteria, :leases, :executions).ordered
      scope = scope.where(status: @status) if @status
      scope = scope.where(kind: params[:kind]) if params[:kind].present?
      if params[:q].present?
        scope = scope.where("LOWER(title) LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].downcase)}%")
      end
      @tickets = scope.limit(500)
      @counts = current_project.tickets.group(:status).count
    end

    def show
      @events = @ticket.events.last(200).reverse
      @executions = @ticket.executions.includes(:verification_results).limit(20)
      @artifacts = @ticket.artifacts.limit(50)
      @approvals = Approval.where(ticket_id: @ticket.id).order(created_at: :desc).limit(20)
      @head_sha = Evidence.head_sha(@ticket)
      @checks = CompletionPolicy.checks_report(@ticket, head_sha: @head_sha)
      @completion = CompletionPolicy.evaluate(@ticket)
      @sessions = @ticket.session_links.includes(:agent_session).order(started_at: :desc).limit(10)
      @providers = Providers.registry.keys.select { |k| Agentboard.config.provider_enabled?(k) }
      @workflows = WorkflowDefinition.where(project: current_project).group_by(&:name).map { |_, v| v.max_by(&:version) }
      @other_tickets = current_project.tickets.where.not(id: @ticket.id).open.ordered.limit(200)
    end

    def new
      @ticket = current_project.tickets.new(kind: "task", priority: 2, status: params[:status].presence_in(%w[backlog ready]) || "backlog")
    end

    def create
      p = ticket_params
      @ticket = Tickets.create!(project: current_project, actor: current_actor, title: p[:title], description: p[:description].to_s,
                                kind: p[:kind].presence || "task", priority: p[:priority].presence || 2,
                                labels: p[:labels].to_s.split(","), criteria: p[:criteria].to_s.lines,
                                status: (p[:status].presence_in(%w[backlog ready]) || "backlog"),
                                parent: p[:parent_id].present? ? current_project.tickets.find(p[:parent_id]) : nil,
                                milestone: p[:milestone_id].present? ? current_project.milestones.find(p[:milestone_id]) : nil)
      redirect_to ticket_path(@ticket), notice: "#{@ticket.key} created"
    rescue Agentboard::Error => e
      @ticket = current_project.tickets.new(title: p[:title], description: p[:description], kind: p[:kind], priority: p[:priority])
      flash.now[:alert] = e.message
      render :new, status: :unprocessable_entity
    end

    def edit; end

    def update
      Tickets.update!(ticket: @ticket, actor: current_actor, attributes: ticket_params.except(:criteria, :status), expected_version: params[:lock_version])
      redirect_to ticket_path(@ticket), notice: "Saved"
    end

    def transition
      to = params.require(:to)
      Tickets.transition!(ticket: @ticket, to: to, actor: current_actor, reason: params[:reason].presence,
                          override_criteria: params[:override_criteria] == "1", verification_requested: params[:verification_requested] == "1",
                          expected_version: params[:lock_version].presence)
      respond_to do |format|
        format.json { render json: Result.success({ key: @ticket.key, status: @ticket.reload.status, version: @ticket.lock_version }).to_h }
        format.html { redirect_back fallback_location: ticket_path(@ticket), notice: "#{@ticket.key} → #{StateMachines::Ticket::LABELS[to]}", status: :see_other }
      end
    end

    # Board drag & drop: server-validated transition plus ordering.
    def move
      to = params.require(:to)
      Tickets.transition!(ticket: @ticket, to: to, actor: current_actor, reason: params[:reason].presence) if to != @ticket.status
      Tickets.reorder!(ticket: @ticket, actor: current_actor, position: params[:position]) if params[:position].present?
      render json: Result.success({ key: @ticket.key, status: @ticket.reload.status }).to_h
    end

    def verify
      results = VerificationService.verify_repository!(ticket: @ticket, actor: current_actor)
      passed = results.count(&:passed?)
      redirect_to ticket_path(@ticket), notice: "Verification finished: #{passed}/#{results.size} checks passed", status: :see_other
    end

    def run
      if params[:workflow].present?
        definition = WorkflowEngine.latest(project: current_project, name: params[:workflow])
        run = WorkflowEngine.start!(definition: definition, ticket: @ticket, actor: current_actor)
        redirect_to workflow_run_path(run), notice: "Workflow #{definition.name} started", status: :see_other
      else
        execution = Executions.enqueue!(ticket: @ticket, provider_key: params.require(:provider), actor: current_actor,
                                        action: params[:action_name].presence || "implement",
                                        idempotency_key: params[:idempotency_key].presence,
                                        metadata: params[:scenario].present? ? { "scenario" => params[:scenario] } : {})
        notice = Runtime::DaemonControl.status[:running] ? "Execution queued" : "Execution queued — start the runtime with `bundle exec agentboard daemon start`"
        redirect_to execution_path(execution), notice: notice, status: :see_other
      end
    end

    def complete
      CompletionPolicy.complete!(ticket: @ticket, actor: current_actor, expected_version: params[:lock_version].presence)
      redirect_to ticket_path(@ticket), notice: "#{@ticket.key} is done", status: :see_other
    end

    def suggestions
      @suggestions = TicketAdvisor.suggest(@ticket)
      render layout: false
    end

    # A human accepts one suggestion; it goes through the normal domain services.
    def accept_suggestion
      value = params.require(:value).to_s
      case params.require(:kind)
      when "criterion" then Tickets.add_criterion!(ticket: @ticket, actor: current_actor, description: value)
      when "subtask"
        Tickets.create!(project: current_project, actor: current_actor, title: value, parent: @ticket, kind: "task", priority: @ticket.priority)
      when "dependency"
        Tickets.add_dependency!(ticket: @ticket, depends_on: Ticket.find_by_key!(value, project: current_project), actor: current_actor)
      when "complexity"
        Tickets.update!(ticket: @ticket, actor: current_actor, attributes: { labels: (@ticket.labels.reject { |l| l.start_with?("size:") } + [ "size:#{value}" ]) })
      else
        raise Error.validation_failed("Unknown suggestion kind")
      end
      redirect_to ticket_path(@ticket), notice: "Suggestion accepted", status: :see_other
    end

    def link_pr
      PullRequests.link_manually!(ticket: @ticket, actor: current_actor, url: params.require(:url), state: params.require(:state),
                                       merge_commit_sha: params[:merge_commit_sha].presence)
      redirect_to ticket_path(@ticket), notice: "Pull request linked", status: :see_other
    end

    private

    def load_ticket = @ticket = find_ticket(params[:key])

    def ticket_params
      params.require(:ticket).permit(:title, :description, :kind, :priority, :labels, :criteria, :status, :milestone_id, :parent_id)
    end
  end
end
