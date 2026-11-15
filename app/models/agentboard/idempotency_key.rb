module Agentboard
  class IdempotencyKey < ApplicationRecord
    validates :scope, :key, :request_digest, presence: true
  end
end
