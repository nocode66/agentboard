module Agentboard
  class Milestone < ApplicationRecord
    belongs_to :project
    has_many :tickets, dependent: :nullify
    validates :name, presence: true
  end
end
