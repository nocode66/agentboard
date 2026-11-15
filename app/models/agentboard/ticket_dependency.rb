module Agentboard
  class TicketDependency < ApplicationRecord
    KINDS = %w[blocks relates].freeze

    belongs_to :ticket
    belongs_to :depends_on_ticket, class_name: "Agentboard::Ticket"

    validates :kind, inclusion: { in: KINDS }
    validates :depends_on_ticket_id, uniqueness: { scope: [ :ticket_id, :kind ] }
    validate :not_self
    validate :acyclic, if: -> { kind == "blocks" }

    private

    def not_self
      errors.add(:depends_on_ticket, "cannot be the ticket itself") if ticket_id == depends_on_ticket_id
    end

    # DAG validation: adding ticket -> dep must not create a path dep ->* ticket.
    def acyclic
      seen = Set.new
      frontier = [ depends_on_ticket_id ]
      while (current = frontier.shift)
        if current == ticket_id
          errors.add(:depends_on_ticket, "would create a dependency cycle")
          return
        end
        next unless seen.add?(current)

        frontier.concat(self.class.where(ticket_id: current, kind: "blocks").pluck(:depends_on_ticket_id))
      end
    end
  end
end
