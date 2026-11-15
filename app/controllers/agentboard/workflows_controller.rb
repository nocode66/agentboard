module Agentboard
  class WorkflowsController < ApplicationController
    SAMPLE = <<~YAML
      version: 1
      name: feature_delivery
      steps:
        - id: plan
          type: agent
          provider: fake
          action: plan
        - id: implement
          type: agent
          provider: fake
          action: implement
          depends_on: [plan]
        - id: test
          type: command
          command: rails_test
          depends_on: [implement]
        - id: review
          type: agent
          provider: fake
          action: review
          depends_on: [test]
        - id: approval
          type: human_approval
          depends_on: [review]
    YAML

    def index
      WorkflowEngine.sync_from_disk!(project: current_project) if params[:sync]
      @definitions = WorkflowDefinition.where(project: current_project).order(:name, version: :desc).group_by(&:name)
      @runs = WorkflowRun.joins(:ticket).where(agentboard_tickets: { project_id: current_project.id }).includes(:ticket, :workflow_definition, :steps)
                         .order(created_at: :desc).limit(30)
      @yaml = params[:yaml].presence || SAMPLE
    end

    def show
      @definition = WorkflowDefinition.where(project: current_project).find(params[:id])
      @parsed = @definition.parsed
    end

    def validate
      definition = Workflows::Definition.parse_yaml(params.require(:yaml), enforce_features: true)
      render json: { ok: true, name: definition.name, steps: definition.topological_order, digest: definition.digest }
    rescue Agentboard::Error => e
      render json: { ok: false, errors: e.details[:errors] || [ e.message ] }, status: :unprocessable_entity
    end

    def create
      definition = WorkflowEngine.register!(project: current_project, yaml: params.require(:yaml), actor: current_actor)
      redirect_to workflow_path(definition), notice: "Registered #{definition.name} v#{definition.version}", status: :see_other
    end

    def start
      definition = WorkflowDefinition.where(project: current_project).find(params[:id])
      ticket = Ticket.find_by_key!(params.require(:ticket_key), project: current_project)
      run = WorkflowEngine.start!(definition: definition, ticket: ticket, actor: current_actor)
      redirect_to workflow_run_path(run), status: :see_other
    end
  end
end
