module Agentboard
  class TicketLease < ApplicationRecord
    belongs_to :ticket
    belongs_to :agent_session, optional: true

    scope :live, -> { where(released_at: nil) }

    def expired?(now = Time.current) = expires_at <= now
    def active?(now = Time.current) = released_at.nil? && !expired?(now)
  end
end
