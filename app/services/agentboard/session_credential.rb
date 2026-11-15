module Agentboard
  # Short-lived local capability credential for MCP sessions (spec §25.4). The MCP process
  # holds the secret in memory; only its digest is stored. Every tool call verifies it, the
  # credential rotates before expiry, and a human can revoke the session at any time.
  module SessionCredential
    TTL = 15.minutes
    ROTATE_BEFORE = 2.minutes

    Credential = Struct.new(:token, :expires_at, keyword_init: true)

    module_function

    def issue!(session)
      token = Ids.token
      expires = Time.current + TTL
      session.update_columns(credential_digest: Ids.digest(token),
                             metadata: session.metadata.merge("credential_expires_at" => expires.utc.iso8601))
      Credential.new(token: token, expires_at: expires)
    end

    # Returns the (possibly rotated) credential or raises UNAUTHORIZED.
    def verify!(session, credential)
      session.reload
      raise Error.unauthorized("Session was revoked by a human") if session.state == "revoked"
      raise Error.unauthorized("Session has ended") if session.state == "ended"
      raise Error.unauthorized("Missing session credential") unless credential
      raise Error.unauthorized("Invalid session credential") unless Ids.secure_match?(credential.token, session.credential_digest)
      raise Error.unauthorized("Session credential expired") if credential.expires_at <= Time.current

      credential.expires_at - Time.current < ROTATE_BEFORE ? issue!(session) : credential
    end

    def revoke!(session, actor:, reason: nil)
      raise Error.forbidden("Only humans can revoke sessions") unless actor.human?
      Authorization.authorize!(actor, "session.manage")

      session.update_columns(state: "revoked", credential_digest: nil, ended_at: Time.current)
      session.leases.live.update_all(released_at: Time.current, release_reason: "session_revoked", updated_at: Time.current)
      SessionTicketLink.active.where(agent_session_id: session.id).update_all(ended_at: Time.current, updated_at: Time.current)
      EventStore.append!(type: "security.session_revoked", aggregate: session, project: session.project, session: session, actor: actor,
                         payload: { reason: reason })
    end
  end
end
