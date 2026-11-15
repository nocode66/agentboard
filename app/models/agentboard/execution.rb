module Agentboard
  # One AgentBoard-managed attempt to perform work. Execution state is independent of
  # ticket state (ADR-004); retries create new rows with incremented `attempt`.
  class Execution < ApplicationRecord
    belongs_to :ticket
    belongs_to :agent_profile, optional: true
    belongs_to :agent_session, optional: true
    belongs_to :workflow_step, optional: true
    has_many :verification_results, -> { order(:started_at) }, dependent: :destroy
    has_many :artifacts, dependent: :nullify
    has_many :usage_records, dependent: :destroy
    has_many :approvals, dependent: :nullify

    validates :status, inclusion: { in: StateMachines::Execution::STATES }
    validates :provider_key, presence: true
    validates :attempt, uniqueness: { scope: :ticket_id }

    scope :active, -> { where(status: StateMachines::Execution::ACTIVE) }
    scope :terminal, -> { where(status: StateMachines::Execution::TERMINAL) }
    scope :recent, -> { order(created_at: :desc) }

    def terminal? = StateMachines::Execution.terminal?(status)
    def active? = !terminal?
    def short_id = id.to_s.split("-").last[0, 8]
    def label = "#{ticket.key} · exec-#{attempt.to_s.rjust(3, "0")}"

    def duration
      return unless started_at

      (finished_at || Time.current) - started_at
    end

    def events
      Agentboard::Event.where(execution_id: id).order(:occurred_at, :sequence)
    end

    def log_tail(bytes: 64 * 1024)
      return "" unless log_path && File.file?(log_path)

      File.open(log_path, "rb") do |f|
        size = f.size
        f.seek([ size - bytes, 0 ].max)
        f.read.to_s.force_encoding("UTF-8").scrub
      end
    end

    def self.next_attempt_for(ticket)
      (where(ticket_id: ticket.id).maximum(:attempt) || 0) + 1
    end
  end
end
