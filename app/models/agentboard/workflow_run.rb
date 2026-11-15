module Agentboard
  class WorkflowRun < ApplicationRecord
    STATUSES = %w[pending running waiting_for_approval succeeded failed cancelled].freeze
    TERMINAL = %w[succeeded failed cancelled].freeze

    belongs_to :workflow_definition
    belongs_to :ticket
    has_many :steps, -> { order(:created_at) }, class_name: "Agentboard::WorkflowStep", dependent: :destroy

    validates :status, inclusion: { in: STATUSES }
    scope :active, -> { where.not(status: TERMINAL) }

    def terminal? = TERMINAL.include?(status)
    def definition = workflow_definition.parsed

    # Latest attempt per step key.
    def current_steps
      steps.group_by(&:step_key).transform_values { |list| list.max_by(&:attempt) }
    end
  end
end
