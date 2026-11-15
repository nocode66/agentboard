module Agentboard
  class OutboxMessage < ApplicationRecord
    STATES = %w[pending delivered dead].freeze
    MAX_ATTEMPTS = 8

    belongs_to :event, class_name: "Agentboard::Event"
    validates :state, inclusion: { in: STATES }

    scope :due, ->(now = Time.current) { where(state: "pending").where("available_at <= ?", now).order(:available_at) }
  end
end
