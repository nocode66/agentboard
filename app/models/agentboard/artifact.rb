module Agentboard
  class Artifact < ApplicationRecord
    KINDS = %w[commit diff log test_report pull_request summary context file link handoff capture screenshot].freeze

    belongs_to :ticket
    belongs_to :execution, optional: true
    validates :kind, inclusion: { in: KINDS }
    validates :uri, presence: true
    validates :provenance, inclusion: { in: Event::PROVENANCE }
  end
end
