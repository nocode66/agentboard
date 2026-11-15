module Agentboard
  # Appends events and their outbox messages in the caller's transaction, giving the
  # transactional state-change + outbox guarantee (spec §11). Consumers must be idempotent;
  # delivery is at-least-once, never exactly-once.
  module EventStore
    DEFAULT_TOPICS = %w[projections].freeze
    MAX_PAYLOAD_BYTES = 64 * 1024

    class Duplicate < StandardError
      attr_reader :event
      def initialize(event) = (@event = event; super("duplicate event #{event.id}"))
    end

    module_function

    # Returns the persisted Event. With a dedupe_key, a replay returns the original event
    # and does not insert a second row (raises Duplicate when raise_on_duplicate).
    def append!(type:, aggregate:, source: "agentboard", provenance: "confirmed", payload: {},
                actor: nil, project: nil, ticket: nil, execution: nil, session: nil,
                correlation_id: nil, causation_id: nil, dedupe_key: nil, occurred_at: nil,
                topics: DEFAULT_TOPICS, raise_on_duplicate: false, event_id: nil)
      if dedupe_key && (existing = Event.find_by(dedupe_key: dedupe_key))
        raise Duplicate, existing if raise_on_duplicate

        return existing
      end

      aggregate_type, aggregate_id = resolve_aggregate(aggregate)
      project_id = project&.id || ticket&.project_id || (aggregate.respond_to?(:project_id) && aggregate.project_id) || nil
      safe_payload = bounded(Redactor.redact_value(deep_stringify(payload)))
      now = Time.current

      attempts = 0
      begin
        attempts += 1
        Event.transaction(requires_new: true) do
          sequence = Event.where(aggregate_type: aggregate_type, aggregate_id: aggregate_id).maximum(:sequence).to_i + 1
          event = Event.create!(
            id: event_id || Ids.uuid, project_id: project_id, aggregate_type: aggregate_type, aggregate_id: aggregate_id,
            sequence: sequence, event_type: type, schema_version: EventSchema.current_version(type), source: source, provenance: provenance,
            ticket_id: ticket&.id || (aggregate.is_a?(Ticket) ? aggregate.id : nil),
            execution_id: execution&.id || (aggregate.is_a?(Execution) ? aggregate.id : nil),
            session_id: session&.id, actor_type: actor&.type, actor_id: actor&.id,
            dedupe_key: dedupe_key, occurred_at: occurred_at || now, received_at: now, payload: safe_payload,
            correlation_id: correlation_id || Current.correlation_id || Ids.correlation, causation_id: causation_id
          )
          Array(topics).each do |topic|
            OutboxMessage.create!(event_id: event.id, topic: topic, state: "pending", available_at: now)
          end
          event
        end
      rescue ActiveRecord::RecordNotUnique => e
        if dedupe_key && (existing = Event.find_by(dedupe_key: dedupe_key))
          raise Duplicate, existing if raise_on_duplicate

          return existing
        end
        retry if attempts < 5
        raise e
      end
    end

    def resolve_aggregate(aggregate)
      case aggregate
      when Array then aggregate.map(&:to_s)
      when ActiveRecord::Base then [ aggregate.class.name.demodulize.underscore, aggregate.id.to_s ]
      else raise ArgumentError, "aggregate must be a record or [type, id]"
      end
    end

    def deep_stringify(value)
      case value
      when Hash then value.to_h { |k, v| [ k.to_s, deep_stringify(v) ] }
      when Array then value.map { |v| deep_stringify(v) }
      when Time, DateTime, ActiveSupport::TimeWithZone then value.utc.iso8601(3)
      when Symbol then value.to_s
      else value
      end
    end

    def bounded(payload)
      json = payload.to_json
      return payload if json.bytesize <= MAX_PAYLOAD_BYTES

      { "truncated" => true, "original_bytes" => json.bytesize, "excerpt" => json.byteslice(0, 4096).scrub }
    end
  end
end
