module Agentboard
  # A provider coding conversation or process identity.
  #
  # trust_level:
  #   "launched"    – started by the AgentBoard runtime (we own the process)
  #   "hook"        – corroborated by a provider hook payload
  #   "mcp_stdio"   – bound to a local MCP stdio process started by the user
  #   "untrusted"   – label supplied by an agent; never authorizes anything
  class AgentSession < ApplicationRecord
    TRUST_LEVELS = %w[launched hook mcp_stdio untrusted].freeze

    belongs_to :project
    has_many :ticket_links, class_name: "Agentboard::SessionTicketLink", dependent: :destroy
    has_many :tickets, through: :ticket_links
    has_many :leases, class_name: "Agentboard::TicketLease", dependent: :nullify
    has_many :executions, dependent: :nullify

    validates :provider_key, presence: true
    validates :trust_level, inclusion: { in: TRUST_LEVELS }

    scope :active, -> { where(state: "active") }

    def active_link = ticket_links.find_by(ended_at: nil)
    def active_ticket = active_link&.ticket
    def actor = Agentboard::Authorization.agent_actor(id, name: display_name)
    def display_name = label.presence || "#{provider_key} #{(external_session_id || id)[0, 8]}"

    def touch_seen! = update_column(:last_seen_at, Time.current)
  end
end
