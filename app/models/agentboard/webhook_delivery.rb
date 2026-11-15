module Agentboard
  class WebhookDelivery < ApplicationRecord
    STATUSES = %w[received processed ignored rejected failed].freeze
    validates :provider, :delivery_id, :event, :payload_digest, presence: true
    validates :status, inclusion: { in: STATUSES }
  end
end
