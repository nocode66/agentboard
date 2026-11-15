module Agentboard
  # A check bound to a specific commit. A result for SHA A never authorizes SHA B (AT-08).
  class VerificationResult < ApplicationRecord
    STATUSES = %w[running passed failed error timeout skipped].freeze
    belongs_to :execution
    validates :status, inclusion: { in: STATUSES }
    validates :commit_sha, :command_digest, :name, presence: true

    def passed? = status == "passed"
    def stale_for?(head_sha) = commit_sha != head_sha
  end
end
