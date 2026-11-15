module Agentboard
  # Pure transition tables. Guards that need persistence (leases, evidence, approvals)
  # are enforced by the domain services in app/services/agentboard.
  module StateMachines
    module Ticket
      STATES = %w[backlog ready claimed in_progress testing review done blocked cancelled reopened].freeze
      TERMINAL = %w[done cancelled].freeze
      NONTERMINAL = (STATES - TERMINAL).freeze
      BOARD_COLUMNS = %w[backlog ready claimed in_progress testing review done].freeze

      # spec §24.1 — anything not listed is INVALID_TRANSITION
      TRANSITIONS = {
        "backlog" => %w[ready blocked cancelled],
        "ready" => %w[claimed blocked cancelled backlog],
        "claimed" => %w[in_progress ready blocked cancelled],
        "in_progress" => %w[testing blocked cancelled],
        "testing" => %w[review in_progress blocked cancelled],
        "review" => %w[done in_progress blocked cancelled],
        "blocked" => %w[ready cancelled],
        "reopened" => %w[ready blocked cancelled],
        "done" => %w[reopened],
        "cancelled" => []
      }.freeze

      LABELS = {
        "backlog" => "Backlog", "ready" => "Ready", "claimed" => "Claimed", "in_progress" => "In progress",
        "testing" => "Testing", "review" => "Review", "done" => "Done", "blocked" => "Blocked",
        "cancelled" => "Cancelled", "reopened" => "Reopened"
      }.freeze

      module_function

      def allowed?(from, to) = TRANSITIONS.fetch(from.to_s, []).include?(to.to_s)
      def next_states(from) = TRANSITIONS.fetch(from.to_s, [])

      def assert!(from, to)
        return if allowed?(from, to)

        raise Error.invalid_transition("Ticket cannot move from #{from} to #{to}", from: from, to: to)
      end
    end

    module Execution
      STATES = %w[queued preparing running waiting_for_input waiting_for_permission verifying completed failed cancelled interrupted].freeze
      TERMINAL = %w[completed failed cancelled interrupted].freeze
      ACTIVE = (STATES - TERMINAL).freeze

      # spec §24.2
      TRANSITIONS = {
        "queued" => %w[preparing cancelled failed],
        "preparing" => %w[running failed cancelled interrupted],
        "running" => %w[verifying waiting_for_input waiting_for_permission failed cancelled interrupted],
        "waiting_for_input" => %w[running failed cancelled interrupted],
        "waiting_for_permission" => %w[running failed cancelled interrupted],
        "verifying" => %w[completed failed cancelled interrupted],
        "completed" => [], "failed" => [], "cancelled" => [], "interrupted" => []
      }.freeze

      module_function

      def allowed?(from, to) = TRANSITIONS.fetch(from.to_s, []).include?(to.to_s)
      def terminal?(state) = TERMINAL.include?(state.to_s)

      def assert!(from, to)
        return if allowed?(from, to)

        raise Error.invalid_transition("Execution cannot move from #{from} to #{to}", from: from, to: to)
      end
    end
  end
end
