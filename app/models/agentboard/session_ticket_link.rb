module Agentboard
  class SessionTicketLink < ApplicationRecord
    # Association precedence (spec §7): lower number wins; automatic sources never
    # replace an explicit human choice.
    SOURCES = { "mcp" => 1, "cli_attach" => 2, "dashboard" => 3, "branch_heuristic" => 4, "provider_metadata" => 5, "runtime" => 0 }.freeze
    EXPLICIT = %w[mcp cli_attach dashboard runtime].freeze

    belongs_to :agent_session
    belongs_to :ticket
    validates :source, inclusion: { in: SOURCES.keys }
    validates :confidence, inclusion: { in: %w[confirmed probable needs_confirmation] }

    scope :active, -> { where(ended_at: nil) }

    def explicit? = EXPLICIT.include?(source)
    def precedence = SOURCES.fetch(source)
  end
end
