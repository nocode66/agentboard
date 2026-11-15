module Agentboard
  class AcceptanceCriterion < ApplicationRecord
    self.table_name = "agentboard_acceptance_criteria"
    VERIFICATION_KINDS = %w[manual test command review].freeze
    STATES = %w[pending verified failed waived].freeze

    belongs_to :ticket
    validates :description, presence: true
    validates :verification_kind, inclusion: { in: VERIFICATION_KINDS }
    validates :state, inclusion: { in: STATES }
    validates :position, uniqueness: { scope: :ticket_id }

    before_validation :assign_position, on: :create

    def satisfied? = %w[verified waived].include?(state)

    private

    def assign_position
      self.position ||= (ticket&.acceptance_criteria&.maximum(:position) || 0) + 1
    end
  end
end
