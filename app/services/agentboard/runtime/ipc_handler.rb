module Agentboard
  module Runtime
    # Maps IPC operations (spec §27.2) to domain services. Runs inside the daemon; every
    # request has already been authenticated by IPC::Server.
    class IpcHandler
      def initialize(supervisor)
        @supervisor = supervisor
      end

      def call(op, params)
        ActiveRecord::Base.connection_pool.with_connection { dispatch(op, params) }
      end

      private

      def actor = Authorization.local_human

      def dispatch(op, params)
        case op
        when "runtime.health" then @supervisor.health
        when "runtime.reconcile" then Reconciler.new.call
        when "execution.enqueue"
          ticket = find_ticket(params)
          execution = Executions.enqueue!(ticket: ticket, provider_key: params.fetch("provider", "fake"), actor: actor,
                                          action: params.fetch("action", "implement"), idempotency_key: params["idempotency_key"],
                                          metadata: params.slice("scenario"))
          { execution_id: execution.id, status: execution.status, attempt: execution.attempt }
        when "execution.status"
          e = Execution.find(params.fetch("execution_id"))
          { execution_id: e.id, state: e.status, attempt: e.attempt, started_at: e.started_at, finished_at: e.finished_at,
            exit_code: e.exit_code, failure_code: e.failure_code, head_sha: e.head_sha }
        when "execution.cancel"
          e = Execution.find(params.fetch("execution_id"))
          Idempotency.call(scope: "execution.cancel", key: params["idempotency_key"], request: params.slice("execution_id", "reason")) do
            e = Executions.request_cancel!(execution: e, actor: actor, reason: params["reason"] || "cancelled via runtime")
            { "accepted" => true, "current_state" => e.status }
          end
        when "execution.input"
          raise Error.capability_unavailable("Interactive input bridging is not supported by the configured providers in print mode")
        when "execution.events"
          e = Execution.find(params.fetch("execution_id"))
          cursor = params["cursor"].to_i
          events = Event.where(aggregate_type: "execution", aggregate_id: e.id).where("sequence > ?", cursor).order(:sequence).limit(500)
          { events: events.map(&:envelope), next_cursor: events.last&.sequence || cursor, terminal: e.reload.terminal? }
        else
          raise Error.not_found("Unknown runtime operation #{op}")
        end
      end

      def find_ticket(params)
        Ticket.find_by_key!(params.fetch("ticket_key"))
      end
    end
  end
end
