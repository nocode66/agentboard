module Agentboard
  # Immutable once used: a changed definition is registered as a new version.
  class WorkflowDefinition < ApplicationRecord
    belongs_to :project
    has_many :workflow_runs, dependent: :restrict_with_exception
    validates :name, :version, :digest, presence: true

    before_update :prevent_mutation_when_used

    def parsed = Agentboard::Workflows::Definition.from_h(definition)

    private

    def prevent_mutation_when_used
      return unless workflow_runs.exists? && (definition_changed? || digest_changed?)

      raise Agentboard::Error.validation_failed("Workflow #{name} v#{version} is immutable once used")
    end
  end
end
