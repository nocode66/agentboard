module Agentboard
  module Runtime
    # Daemon main loop (spec §27.3). Claims queued executions up to the concurrency limit,
    # runs each in a bounded worker thread, drains the outbox, advances workflows and expires
    # approvals. Never blocks the loop on a single process.
    class Supervisor
      attr_reader :started_at, :workers

      def initialize(config: Agentboard.config, logger: Agentboard.logger)
        @config = config
        @logger = logger
        @workers = {}
        @mutex = Mutex.new
        @stopping = false
        @started_at = Time.current
      end

      def run(once: false)
        Reconciler.new(logger: @logger).call
        loop do
          tick
          break if once || @stopping

          sleep @config.runtime["poll_interval"].to_f.clamp(0.05, 10)
        end
        shutdown
      end

      def stop! = (@stopping = true)
      def active_count = @mutex.synchronize { @workers.count { |_, t| t.alive? } }

      def tick
        reap
        start_queued
        WorkflowEngine.tick
        Outbox.drain(limit: 200)
        Approvals.expire_due!
        Extensions.run(:runtime_tick)
      rescue StandardError => e
        @logger.error("[agentboard] supervisor tick failed: #{e.class}: #{Redactor.redact(e.message)}")
      end

      # Fair queue: explicit priority, then age; one active execution per ticket.
      def start_queued
        capacity = @config.max_concurrent_executions - active_count
        return if capacity <= 0

        candidates = Execution.where(status: "queued").joins(:ticket)
                              .order("agentboard_tickets.priority ASC, agentboard_executions.created_at ASC").limit(capacity * 4)
        candidates.each do |execution|
          break if capacity <= 0
          next if @workers.key?(execution.id)
          next if Execution.active.where(ticket_id: execution.ticket_id).where.not(id: execution.id).where.not(status: "queued").exists?

          claimed = Execution.where(id: execution.id, status: "queued").update_all(updated_at: Time.current, heartbeat_at: Time.current)
          next if claimed.zero?

          capacity -= 1
          spawn_worker(execution.id)
        end
      end

      def spawn_worker(execution_id)
        thread = Thread.new do
          Thread.current.name = "agentboard-exec-#{execution_id[0, 8]}"
          ActiveRecord::Base.connection_pool.with_connection do
            ExecutionRunner.new(Execution.find(execution_id), config: @config).call
          end
        rescue StandardError => e
          @logger.error("[agentboard] worker #{execution_id} failed: #{e.class}")
        end
        @mutex.synchronize { @workers[execution_id] = thread }
      end

      def reap
        @mutex.synchronize { @workers.delete_if { |_, t| !t.alive? } }
      end

      # Graceful shutdown: request cancellation of running work and wait briefly. Anything
      # still running is reconciled as interrupted on the next start.
      def shutdown
        ids = @mutex.synchronize { @workers.keys }
        return if ids.empty?

        Execution.where(id: ids).active.update_all(cancel_requested_at: Time.current, cancel_reason: "daemon shutdown")
        deadline = Subprocess.monotonic + @config.runtime["cancel_grace_seconds"].to_i + 5
        sleep 0.1 while Subprocess.monotonic < deadline && active_count.positive?
      end

      def health
        { version: Agentboard::VERSION, pid: ::Process.pid, uptime: (Time.current - @started_at).round, active: active_count,
          queued: Execution.where(status: "queued").count, max_concurrent: @config.max_concurrent_executions }
      end
    end
  end
end
