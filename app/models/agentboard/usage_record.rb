module Agentboard
  # Token/cost metering. Unknown cost is nil, never zero; monetary amounts require
  # provenance. `metering_kind` distinguishes API-billed from subscription CLI usage.
  class UsageRecord < ApplicationRecord
    METERING_KINDS = %w[api_billed subscription unknown].freeze
    belongs_to :execution
    validates :metering_kind, inclusion: { in: METERING_KINDS }
    validates :source, presence: true
  end
end
