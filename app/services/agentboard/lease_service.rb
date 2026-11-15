module Agentboard
  # Exclusive, expiring ticket leases with monotonic fencing tokens (spec §23.3).
  #
  # Exclusivity is enforced twice: by a row lock on the ticket inside a transaction and by a
  # partial unique index (one unreleased lease per ticket). Only the SHA-256 digest of the
  # bearer token is stored.
  module LeaseService
    Claim = Struct.new(:lease, :token, keyword_init: true)

    module_function

    def claim!(ticket:, actor:, session: nil, lease_seconds: nil, expected_version: nil, correlation_id: nil)
      Authorization.authorize!(actor, "ticket.claim")
      seconds = clamp_seconds(lease_seconds)
      token = Ids.token

      ticket.class.transaction do
        ticket.lock!
        if expected_version && ticket.lock_version != expected_version.to_i
          raise Error.version_conflict("Ticket #{ticket.key} is at version #{ticket.lock_version}, expected #{expected_version}",
                                       ticket_key: ticket.key, current_version: ticket.lock_version)
        end

        now = Time.current
        expire_stale!(ticket, now)
        if (live = ticket.leases.live.first)
          if session && live.agent_session_id == session.id
            raise Error.lease_conflict("This session already holds the lease for #{ticket.key}; release it or use the existing token", ticket_key: ticket.key)
          end

          raise Error.lease_conflict("Ticket is claimed by another active session", ticket_key: ticket.key, expires_at: live.expires_at.utc.iso8601)
        end

        unless ticket.status == "ready"
          raise Error.invalid_transition("Only ready tickets can be claimed (#{ticket.key} is #{ticket.status})", ticket_key: ticket.key, status: ticket.status)
        end
        unless ticket.dependencies_satisfied?
          raise Error.policy_denied("#{ticket.key} has unfinished dependencies: #{ticket.unsatisfied_dependencies.map(&:key).join(", ")}")
        end

        fencing = ticket.fencing_counter + 1
        lease = ticket.leases.create!(agent_session: session, holder_label: session&.display_name || actor.label,
                                      token_digest: Ids.digest(token), fencing_token: fencing, expires_at: now + seconds)
        from = ticket.status
        ticket.update!(fencing_counter: fencing, status: "claimed")
        EventStore.append!(type: "ticket.claimed", aggregate: ticket, ticket: ticket, actor: actor, session: session,
                           correlation_id: correlation_id,
                           payload: { from: from, to: "claimed", fencing_token: fencing, lease_id: lease.id, expires_at: lease.expires_at, holder: lease.holder_label })
        Claim.new(lease: lease, token: token)
      end
    end

    # Validates a presented bearer token for the ticket. Returns the live lease.
    def validate!(ticket:, token:, session: nil, now: Time.current)
      raise Error.unauthorized("A lease_token is required") if token.blank?

      lease = TicketLease.find_by(token_digest: Ids.digest(token))
      raise Error.unauthorized("Invalid lease token") unless lease && lease.ticket_id == ticket.id
      if session && lease.agent_session_id && lease.agent_session_id != session.id
        raise Error.unauthorized("Lease belongs to a different session")
      end
      raise Error.lease_expired("Lease for #{ticket.key} was released (#{lease.release_reason})", ticket_key: ticket.key) if lease.released_at
      raise Error.lease_expired("Lease for #{ticket.key} expired at #{lease.expires_at.utc.iso8601}", ticket_key: ticket.key) if lease.expired?(now)
      # Fencing: a newer lease supersedes any older token even if not yet cleaned up.
      if lease.fencing_token < ticket.reload.fencing_counter
        raise Error.lease_expired("Lease superseded by a newer fencing token", ticket_key: ticket.key)
      end

      lease
    end

    def heartbeat!(ticket:, token:, session: nil, lease_seconds: nil)
      lease = validate!(ticket: ticket, token: token, session: session)
      lease.update!(expires_at: Time.current + clamp_seconds(lease_seconds))
      lease
    end

    def release!(ticket:, token: nil, actor:, session: nil, reason: "released", lease: nil, return_to_ready: true, correlation_id: nil)
      ticket.class.transaction do
        ticket.lock!
        lease ||= validate!(ticket: ticket, token: token, session: session)
        lease.update!(released_at: Time.current, release_reason: reason.to_s[0, 200])
        from = ticket.status
        if return_to_ready && ticket.status == "claimed"
          ticket.update!(status: "ready")
        end
        EventStore.append!(type: "ticket.lease_released", aggregate: ticket, ticket: ticket, actor: actor, session: session,
                           correlation_id: correlation_id, payload: { lease_id: lease.id, reason: reason, from: from, to: ticket.status })
        lease
      end
    end

    # Human/system release of whatever lease is live (e.g. on cancel or done).
    def release_all!(ticket:, reason:)
      ticket.leases.live.update_all(released_at: Time.current, release_reason: reason.to_s[0, 200], updated_at: Time.current)
    end

    def expire_stale!(ticket, now = Time.current)
      ticket.leases.live.where("expires_at <= ?", now).update_all(released_at: now, release_reason: "expired", updated_at: now)
    end

    def clamp_seconds(value)
      cfg = Agentboard.config.leases
      (value || cfg["default_seconds"]).to_i.clamp(cfg["min_seconds"].to_i, cfg["max_seconds"].to_i)
    end
  end
end
