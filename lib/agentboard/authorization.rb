module Agentboard
  # Role-based permissions (spec §14). Agents receive narrowly scoped permissions and
  # can never satisfy human-only guards (approvals, reopen, completion override).
  module Authorization
    ROLES = %w[viewer developer maintainer administrator].freeze

    PERMISSIONS = {
      "ticket.read" => %w[viewer developer maintainer administrator agent],
      "ticket.write" => %w[developer maintainer administrator],
      "ticket.transition" => %w[developer maintainer administrator agent],
      "ticket.comment" => %w[developer maintainer administrator agent],
      "ticket.claim" => %w[developer maintainer administrator agent],
      "ticket.complete" => %w[maintainer administrator],
      "ticket.reopen" => %w[maintainer administrator],
      "ticket.cancel" => %w[developer maintainer administrator],
      "execution.start" => %w[developer maintainer administrator],
      "execution.cancel" => %w[developer maintainer administrator],
      "approval.request" => %w[developer maintainer administrator agent],
      "approval.decide" => %w[maintainer administrator],
      "workflow.manage" => %w[maintainer administrator],
      "session.manage" => %w[maintainer administrator],
      "settings.manage" => %w[administrator]
    }.freeze

    # Transitions an agent identity may never perform on its own.
    HUMAN_ONLY_TRANSITIONS = %w[done reopened cancelled backlog].freeze

    # An actor is anything responding to #role, #type ("human"/"agent"/"system") and #id.
    Actor = Struct.new(:type, :id, :role, :name, keyword_init: true) do
      def agent? = type == "agent"
      def human? = type == "human"
      def system? = type == "system"
      def label = name || "#{type}:#{id}"
    end

    module_function

    def system_actor = Actor.new(type: "system", id: "agentboard", role: "administrator", name: "AgentBoard")
    def local_human(name = ENV["USER"] || "local") = Actor.new(type: "human", id: name, role: "administrator", name: name)

    def agent_actor(session_id, name: nil)
      Actor.new(type: "agent", id: session_id.to_s, role: "agent", name: name || "agent:#{session_id.to_s[0, 8]}")
    end

    def allowed?(actor, permission)
      return false unless actor
      return true if actor.system?

      PERMISSIONS.fetch(permission) { raise ArgumentError, "unknown permission #{permission}" }.include?(actor.role.to_s)
    end

    def authorize!(actor, permission)
      return true if allowed?(actor, permission)

      raise Error.forbidden("#{actor&.label || "anonymous"} is not allowed to #{permission}", permission: permission)
    end
  end
end
