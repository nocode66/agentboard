module Agentboard
  # Receives provider hook payloads (spec §7): validate, redact, normalize, deduplicate,
  # associate with sessions, and queue. Payloads are bounded; only documented fields are kept.
  module HookIngestion
    MAX_PAYLOAD_BYTES = 256 * 1024

    module_function

    def ingest!(provider_key:, event_name:, raw:, project: Project.current, received_at: Time.current)
      raise Error.validation_failed("payload too large") if raw.to_s.bytesize > MAX_PAYLOAD_BYTES
      raise Error.validation_failed("invalid event name") unless event_name.to_s.match?(/\A[A-Za-z_.\-]{1,64}\z/)

      payload = raw.to_s.strip.empty? ? {} : JSON.parse(raw)
      raise Error.validation_failed("hook payload must be a JSON object") unless payload.is_a?(Hash)

      provider = Providers.registry.fetch(provider_key)
      events = provider.parse_hook(event_name: event_name, payload: payload)
      raw_digest = Digest::SHA256.hexdigest(raw.to_s)

      events.map.with_index do |ev, i|
        session = resolve_session(project, provider_key, ev.external_session_id, payload)
        dedupe = "hook:#{provider_key}:#{raw_digest}:#{i}"
        ticket = session&.active_ticket
        event = EventStore.append!(type: ev.type, aggregate: session || [ "project", project.id ], project: project, ticket: ticket,
                                   session: session, source: "hook.#{provider_key}", provenance: "provider_reported",
                                   payload: ev.payload.merge("hook_event" => event_name), dedupe_key: dedupe)
        if session && session.metadata["agent_pid"].nil?
          SessionCorrelation.record_agent!(session, ProcessAncestry.find_agent)
        end
        maybe_associate_from_branch(session, project, payload) if session && ev.type == "agent.session.started" && session.reload.active_link.nil?
        if session && ev.type == "agent.session.ended"
          session.update!(state: "ended", ended_at: Time.current)
        end
        event
      end
    rescue JSON::ParserError
      raise Error.validation_failed("hook payload is not valid JSON")
    end

    # A hook-reported session id is corroborated by the provider runtime (trust "hook").
    def resolve_session(project, provider_key, external_id, payload)
      return nil if external_id.blank?

      external_id = external_id.to_s[0, 128]
      session = AgentSession.find_or_create_by!(project: project, provider_key: provider_key, external_session_id: external_id) do |s|
        s.trust_level = "hook"
        s.state = "active"
        s.cwd = payload["cwd"].to_s[0, 500].presence
        s.label = "#{Providers.registry.adapter_class(provider_key).display_name} #{external_id[0, 8]}"
      end
      fresh = session.state == "active" && session.last_seen_at && session.last_seen_at > 1.minute.ago
      session.update_columns(last_seen_at: Time.current, state: "active") unless fresh
      session
    rescue ActiveRecord::RecordNotUnique
      AgentSession.find_by!(project: project, provider_key: provider_key, external_session_id: external_id)
    end

    # Branch-name heuristic (precedence 4): recorded as needs_confirmation, never overrides explicit links.
    def maybe_associate_from_branch(session, project, payload)
      return if session.active_link

      cwd = payload["cwd"].presence || project.root_path
      branch = Git::Repository.new(cwd).current_branch(chdir: cwd)
      ticket = SessionAssociation.ticket_from_branch(branch, project: project)
      return unless ticket

      SessionAssociation.link!(session: session, ticket: ticket, source: "branch_heuristic", confidence: "needs_confirmation",
                               actor: Authorization.system_actor)
    rescue StandardError
      nil
    end

    # Local spooling when the database is unavailable: payloads are appended (redacted) to a
    # user-private spool file and replayed by `agentboard hook replay` / the daemon.
    def spool!(root:, provider_key:, event_name:, raw:)
      dir = File.join(root.to_s, ".agentboard", "spool")
      FileUtils.mkdir_p(dir, mode: 0o700)
      line = { provider: provider_key, event: event_name, raw: Redactor.redact(raw.to_s[0, MAX_PAYLOAD_BYTES]), at: Time.now.utc.iso8601 }.to_json
      File.open(File.join(dir, "hooks.jsonl"), "a", 0o600) { |f| f.flock(File::LOCK_EX); f.puts(line) }
    end

    def replay_spool!(root:)
      path = File.join(root.to_s, ".agentboard", "spool", "hooks.jsonl")
      return 0 unless File.exist?(path)

      processing = "#{path}.#{Process.pid}.processing"
      File.rename(path, processing)
      count = 0
      File.foreach(processing) do |line|
        entry = JSON.parse(line)
        ingest!(provider_key: entry["provider"], event_name: entry["event"], raw: entry["raw"])
        count += 1
      rescue StandardError => e
        Agentboard.logger.warn("[agentboard] spool replay skipped entry: #{e.class}")
      end
      File.delete(processing)
      count
    end
  end
end
