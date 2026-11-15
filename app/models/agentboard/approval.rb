module Agentboard
  # Human authorization bound to an exact action digest, code state (head SHA),
  # execution, requester, expiry and required role (spec §28.5).
  class Approval < ApplicationRecord
    DECISIONS = %w[pending approved rejected expired invalidated].freeze
    ACTION_KINDS = %w[
      review_completion destructive_migration privileged_shell protected_branch_merge
      credential_access production_deploy security_policy_change workflow_gate custom
    ].freeze

    belongs_to :project
    belongs_to :execution, optional: true
    validates :decision, inclusion: { in: DECISIONS }
    validates :action_kind, inclusion: { in: ACTION_KINDS }
    validates :action_digest, :requested_by, presence: true

    scope :pending, -> { where(decision: "pending") }

    def ticket = ticket_id && Agentboard::Ticket.find_by(id: ticket_id)
    def expired?(now = Time.current) = expires_at.present? && expires_at <= now
    def pending? = decision == "pending"

    # Approved, unexpired, and still bound to the same action and code state.
    def valid_for?(action_digest:, head_sha: nil, now: Time.current)
      decision == "approved" && !expired?(now) &&
        self.action_digest == action_digest && (self.head_sha.nil? || self.head_sha == head_sha)
    end
  end
end
