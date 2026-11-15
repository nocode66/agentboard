module Agentboard
  class Ticket < ApplicationRecord
    KINDS = %w[feature bug task chore spike].freeze
    PRIORITIES = { 0 => "Urgent", 1 => "High", 2 => "Medium", 3 => "Low" }.freeze
    KEY_FORMAT = /\A([A-Z][A-Z0-9_-]*)-(\d+)\z/

    belongs_to :project
    belongs_to :milestone, optional: true
    belongs_to :parent, class_name: "Agentboard::Ticket", optional: true
    has_many :subtasks, class_name: "Agentboard::Ticket", foreign_key: :parent_id, dependent: :nullify
    has_many :acceptance_criteria, -> { order(:position) }, class_name: "Agentboard::AcceptanceCriterion", dependent: :destroy
    has_many :comments, -> { order(:created_at) }, dependent: :destroy
    has_many :dependencies, class_name: "Agentboard::TicketDependency", dependent: :destroy
    has_many :depends_on, through: :dependencies, source: :depends_on_ticket
    has_many :inverse_dependencies, class_name: "Agentboard::TicketDependency", foreign_key: :depends_on_ticket_id, dependent: :destroy
    has_many :dependents, through: :inverse_dependencies, source: :ticket
    has_many :leases, class_name: "Agentboard::TicketLease", dependent: :destroy
    has_many :session_links, class_name: "Agentboard::SessionTicketLink", dependent: :destroy
    has_many :agent_sessions, through: :session_links # no DISTINCT: PostgreSQL has no equality for json columns
    has_many :executions, -> { order(created_at: :desc) }, dependent: :restrict_with_exception
    has_many :artifacts, -> { order(created_at: :desc) }, dependent: :destroy
    has_many :workflow_runs, dependent: :restrict_with_exception
    belongs_to :assignee_profile, class_name: "Agentboard::AgentProfile", optional: true

    validates :title, presence: true, length: { maximum: 255 }
    validates :number, presence: true, uniqueness: { scope: :project_id }
    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: StateMachines::Ticket::STATES }
    validates :priority, inclusion: { in: PRIORITIES.keys }

    scope :open, -> { where.not(status: StateMachines::Ticket::TERMINAL) }
    scope :ordered, -> { order(:priority, :position, :number) }

    def self.find_by_key!(key, project: nil)
      match = KEY_FORMAT.match(key.to_s.strip.upcase)
      raise Agentboard::Error.not_found("Ticket #{key} not found") unless match

      scope = joins(:project).where(agentboard_projects: { key: match[1] }, number: match[2].to_i)
      scope = scope.where(project_id: project.id) if project
      scope.first or raise Agentboard::Error.not_found("Ticket #{key} not found")
    end

    def self.find_by_key(key, project: nil)
      find_by_key!(key, project: project)
    rescue Agentboard::Error
      nil
    end

    def key = "#{project.key}-#{number}"
    def to_param = key
    def priority_label = PRIORITIES[priority]
    def status_label = StateMachines::Ticket::LABELS[status]
    def terminal? = StateMachines::Ticket::TERMINAL.include?(status)

    def active_lease
      leases.where(released_at: nil).where("expires_at > ?", Time.current).first
    end

    def active_execution = executions.where(status: StateMachines::Execution::ACTIVE).first

    def dependencies_satisfied?
      depends_on.where.not(status: "done").none?
    end

    def unsatisfied_dependencies = depends_on.where.not(status: "done")

    def criteria_progress
      total = acceptance_criteria.size
      done = acceptance_criteria.count { |c| %w[verified waived].include?(c.state) }
      [ done, total ]
    end

    def events
      Agentboard::Event.where(ticket_id: id).order(:occurred_at, :sequence)
    end

    def latest_head_sha
      executions.where.not(head_sha: nil).pick(:head_sha)
    end
  end
end
