module Agentboard
  module Runtime
    # Restart reconciliation (spec §27.4, AT-07). For every non-terminal execution owned by
    # a previous daemon: the stdout pipe is gone, so the attempt cannot be safely reattached.
    # Live orphan processes are terminated; the attempt is marked `interrupted` with worktree
    # and logs preserved. Uncertain operations are never re-run automatically.
    class Reconciler
      def initialize(logger: Agentboard.logger)
        @logger = logger
      end

      def call
        report = { recovered: [], interrupted: [], orphaned: [] }
        Execution.where(status: StateMachines::Execution::ACTIVE - [ "queued" ]).find_each do |execution|
          AgentContainer.remove(execution.metadata["container"]) if execution.metadata["container"]
          if execution.pid && Subprocess.alive?(execution.pid) && fingerprint_matches?(execution)
            Subprocess.terminate(execution.pgid || execution.pid, grace: Agentboard.config.runtime["cancel_grace_seconds"].to_i)
            report[:orphaned] << execution.id
          end
          Executions.transition!(execution, "interrupted", failure_code: "runtime_restart",
                                                           failure_message: "Runtime restarted while the attempt was #{execution.status}; retry explicitly.")
          execution.ticket.leases.live.where(agent_session_id: execution.agent_session_id)
                   .update_all(released_at: Time.current, release_reason: "execution_interrupted", updated_at: Time.current)
          report[:interrupted] << execution.id
        rescue StandardError => e
          @logger.error("[agentboard] reconcile #{execution.id} failed: #{e.class}")
        end
        if report.values.any?(&:any?)
          EventStore.append!(type: "agent.runtime.reconciled", aggregate: [ "runtime", "local" ], payload: report)
        end
        report
      end

      private

      # PIDs are reused by the OS; only signal a process whose identity still matches.
      def fingerprint_matches?(execution)
        execution.process_fingerprint.present? && Subprocess.fingerprint(execution.pid) == execution.process_fingerprint
      end
    end
  end
end
