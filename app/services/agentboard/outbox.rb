module Agentboard
  # At-least-once dispatcher for outbox messages with bounded retries, exponential
  # backoff and dead-lettering. Subscribers must be idempotent (they may see an event twice).
  module Outbox
    BACKOFF = [ 1, 5, 15, 60, 300, 900, 1800, 3600 ].freeze

    module_function

    def subscribers = (@subscribers ||= Hash.new { |h, k| h[k] = [] })

    def subscribe(topic, callable = nil, &block)
      subscribers[topic.to_s] << (callable || block)
    end

    def reset! = @subscribers = nil

    # Delivers up to `limit` due messages; returns count delivered.
    def drain(limit: 100, now: Time.current)
      delivered = 0
      OutboxMessage.due(now).limit(limit).includes(:event).find_each do |msg|
        # Claim the message atomically so concurrent drainers don't double-process eagerly.
        claimed = OutboxMessage.where(id: msg.id, state: "pending", attempts: msg.attempts)
                               .update_all(attempts: msg.attempts + 1, updated_at: now)
        next if claimed.zero?

        begin
          subscribers[msg.topic].each { |s| s.call(msg.event) }
          msg.update_columns(state: "delivered", delivered_at: Time.current, attempts: msg.attempts + 1)
          delivered += 1
        rescue StandardError => e
          attempts = msg.attempts + 1
          state = attempts >= OutboxMessage::MAX_ATTEMPTS ? "dead" : "pending"
          msg.update_columns(state: state, attempts: attempts, last_error: Redactor.redact("#{e.class}: #{e.message}")[0, 2000],
                             available_at: Time.current + BACKOFF.fetch(attempts - 1, 3600))
        end
      end
      delivered
    end

    def stats
      OutboxMessage.group(:state).count
    end
  end
end
