module Agentboard
  class Comment < ApplicationRecord
    belongs_to :ticket
    validates :body, presence: true, length: { maximum: 20_000 }
    validates :actor_type, inclusion: { in: %w[human agent system] }

    def agent? = actor_type == "agent"
  end
end
