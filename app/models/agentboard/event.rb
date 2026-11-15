module Agentboard
  # Application-append-only event log (spec §11). Rows are never updated by the
  # application; privacy retention is enforced separately.
  class Event < ApplicationRecord
    PROVENANCE = %w[confirmed provider_reported git_observed inferred].freeze
    PROVENANCE_LABELS = {
      "confirmed" => "Confirmed by AgentBoard",
      "provider_reported" => "Reported by provider",
      "git_observed" => "Observed in Git",
      "inferred" => "Inferred"
    }.freeze

    validates :provenance, inclusion: { in: PROVENANCE }
    validates :event_type, :aggregate_type, :aggregate_id, :source, :correlation_id, presence: true

    before_update { raise ActiveRecord::ReadOnlyRecord, "events are append-only" }

    scope :chronological, -> { order(:received_at, :id) }

    def family = event_type.split(".").first

    # Payload in the current schema version (upcast on read; the stored row is untouched).
    def data = EventSchema.upcast(event_type, schema_version, payload)

    def envelope
      {
        event_id: id, schema_version: EventSchema.current_version(event_type), type: event_type, source: source,
        provenance: provenance, project_id: project_id, ticket_id: ticket_id,
        execution_id: execution_id, session_id: session_id, correlation_id: correlation_id,
        causation_id: causation_id, aggregate: { type: aggregate_type, id: aggregate_id, sequence: sequence },
        occurred_at: occurred_at&.utc&.iso8601(3), received_at: received_at&.utc&.iso8601(3),
        stored_schema_version: schema_version,
        payload: data
      }
    end
  end
end
