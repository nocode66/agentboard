module Agentboard
  class AgentProfile < ApplicationRecord
    belongs_to :project
    has_many :executions, dependent: :nullify
    validates :name, presence: true, uniqueness: { scope: :project_id }
    validates :provider_key, presence: true

    def provider = Agentboard::Providers.registry.fetch(provider_key)

    def self.default_for(project, provider_key)
      find_or_create_by!(project: project, name: "#{provider_key}-default") do |p|
        p.provider_key = provider_key.to_s
      end
    end
  end
end
