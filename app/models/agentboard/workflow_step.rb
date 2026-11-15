module Agentboard
  class WorkflowStep < ApplicationRecord
    STATUSES = %w[pending running waiting succeeded failed skipped cancelled].freeze
    TERMINAL = %w[succeeded failed skipped cancelled].freeze

    belongs_to :workflow_run
    has_many :executions, dependent: :nullify
    validates :status, inclusion: { in: STATUSES }

    def terminal? = TERMINAL.include?(status)
  end
end
