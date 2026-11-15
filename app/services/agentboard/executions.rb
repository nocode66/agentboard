module Agentboard
  # Execution lifecycle operations shared by the dashboard, CLI, IPC and workflow engine.
  # The database is the source of truth; the runtime daemon claims queued rows.
  module Executions
    RUNNABLE_TICKET_STATES = %w[ready claimed in_progress testing].freeze

    module_function

    def enqueue!(ticket:, provider_key:, actor:, action: "implement", profile: nil, workflow_step: nil,
                 idempotency_key: nil, metadata: {}, correlation_id: nil)
      Authorization.authorize!(actor, "execution.start") unless actor.system?
      request = { ticket_id: ticket.id, provider_key: provider_key.to_s, action: action, step: workflow_step&.id }
      response = Idempotency.call(scope: "execution.enqueue", key: idempotency_key, request: request) do
        execution = create_queued!(ticket: ticket, provider_key: provider_key.to_s, actor: actor, action: action, profile: profile,
                                   workflow_step: workflow_step, idempotency_key: idempotency_key, metadata: metadata, correlation_id: correlation_id)
        { "execution_id" => execution.id, "status" => execution.status }
      end
      Execution.find(response["execution_id"])
    end

    def create_queued!(ticket:, provider_key:, actor:, action:, profile:, workflow_step:, idempotency_key:, metadata:, correlation_id:)
      provider = Providers.registry.fetch(provider_key)
      unless Agentboard.config.provider_enabled?(provider_key)
        raise Error.policy_denied("Provider #{provider_key} is disabled in configuration")
      end
      if Agentboard.config.provider_settings(provider_key)["active"] == false
        raise Error.policy_denied("Active execution is disabled for #{provider_key}")
      end
      probe = provider.probe
      raise Error.provider_unavailable("#{provider.display_name} is not installed") unless probe.installed || AgentContainer.enabled?
      unless probe.supports?(:active_execution) || (AgentContainer.enabled? && !probe.installed)
        raise Error.capability_unavailable("#{provider.display_name} #{probe.version} cannot run active executions: #{probe.diagnostics.first}")
      end
      enforce_isolation_policy!(provider_key)

      profile ||= AgentProfile.default_for(ticket.project, provider_key)
      Execution.transaction do
        ticket.lock!
        unless RUNNABLE_TICKET_STATES.include?(ticket.status) || (workflow_step && ticket.status == "review")
          raise Error.invalid_transition("#{ticket.key} is #{ticket.status}; executions need a ready or in-flight ticket")
        end
        raise Error.policy_denied("#{ticket.key} has unfinished dependencies") unless ticket.dependencies_satisfied?
        if (running = ticket.executions.active.first) && workflow_step.nil?
          raise Error.workspace_conflict("#{ticket.key} already has an active execution (#{running.label})")
        end

        session = AgentSession.create!(project: ticket.project, provider_key: provider_key, trust_level: "launched",
                                       label: "#{provider.display_name} · #{ticket.key}", state: "active", last_seen_at: Time.current)
        acquire_lease_for!(ticket, session, actor)

        execution = Execution.create!(
          ticket: ticket, agent_profile: profile, agent_session: session, workflow_step: workflow_step,
          provider_key: provider_key, action: action, status: "queued", attempt: Execution.next_attempt_for(ticket),
          idempotency_key: idempotency_key,
          metadata: metadata.to_h.merge("requested_by" => actor.label, "probe_version" => probe.version,
                                        "isolation" => AgentContainer.enabled? ? "container" : "local")
        )
        EventStore.append!(type: "agent.execution.queued", aggregate: execution, ticket: ticket, execution: execution, session: session,
                           actor: actor, correlation_id: correlation_id,
                           payload: { provider: provider_key, action: action, attempt: execution.attempt, profile: profile.name })
        execution
      end
    end

    # Spec §35.2 recommended default: trusted local subprocess execution is opt-in; untrusted
    # work requires a container sandbox. The built-in fake provider is always allowed.
    def enforce_isolation_policy!(provider_key)
      return if provider_key.to_s == "fake"

      sec = Agentboard.config.security
      if AgentContainer.enabled?
        raise Error.capability_unavailable("sandbox.agents is on but #{AgentContainer.runtime} is not running") unless ContainerSandbox.available?

        AgentContainer.image # validates configuration
        return
      end
      return if sec["trusted_local_execution"]

      if sec["sandbox"].to_s == "container"
        raise Error.capability_unavailable("Set sandbox.agents: true (with sandbox.agent_image) to run agents in containers, " \
                                           "or security.trusted_local_execution: true to run them as trusted local subprocesses")
      end
      raise Error.policy_denied("Active execution requires security.trusted_local_execution: true (agents run as your user; worktrees are not sandboxes)")
    end

    def acquire_lease_for!(ticket, session, actor)
      LeaseService.expire_stale!(ticket)
      live = ticket.leases.live.first
      if live
        if live.agent_session_id && live.agent_session&.trust_level != "launched"
          raise Error.lease_conflict("#{ticket.key} is leased by #{live.holder_label}")
        end
        if live.agent_session&.trust_level == "launched" && live.agent_session.executions.active.exists?
          raise Error.lease_conflict("#{ticket.key} is leased by a running execution")
        end

        # Human-held or finished-runtime lease: hand over to this execution's session.
        live.update!(agent_session: session, holder_label: session.display_name,
                     expires_at: Time.current + Agentboard.config.runtime["execution_timeout_seconds"].to_i + 300)
      elsif ticket.status == "ready"
        claim = LeaseService.claim!(ticket: ticket, actor: Authorization.system_actor, session: session,
                                    lease_seconds: Agentboard.config.leases["max_seconds"])
        claim.lease.update!(expires_at: Time.current + Agentboard.config.runtime["execution_timeout_seconds"].to_i + 300)
      else
        fencing = ticket.fencing_counter + 1
        ticket.leases.create!(agent_session: session, holder_label: session.display_name, token_digest: Ids.digest(Ids.token),
                              fencing_token: fencing, expires_at: Time.current + Agentboard.config.runtime["execution_timeout_seconds"].to_i + 300)
        ticket.update!(fencing_counter: fencing)
      end
    end

    def transition!(execution, to, **attrs)
      Execution.transaction do
        execution.lock!
        from = execution.status
        return execution if from == to.to_s

        StateMachines::Execution.assert!(from, to)
        now = Time.current
        updates = attrs.merge(status: to.to_s)
        updates[:started_at] ||= now if to.to_s == "running" && execution.started_at.nil?
        updates[:finished_at] = now if StateMachines::Execution.terminal?(to)
        execution.update!(updates)
        EventStore.append!(type: "agent.execution.#{to}", aggregate: execution, ticket: execution.ticket, execution: execution,
                           session: execution.agent_session, actor: Authorization.system_actor,
                           payload: { from: from, to: to.to_s, exit_code: attrs[:exit_code], failure_code: attrs[:failure_code],
                                      reason: attrs[:failure_message] || attrs[:cancel_reason] }.compact)
        if StateMachines::Execution.terminal?(to)
          execution.agent_session&.update!(state: "ended", ended_at: now)
          WorkflowEngine.step_execution_finished(execution) if execution.workflow_step_id
        end
        execution
      end
    end

    def request_cancel!(execution:, actor:, reason: "cancelled by user")
      Authorization.authorize!(actor, "execution.cancel") unless actor.system?
      Execution.transaction do
        execution.lock!
        return execution if execution.terminal?

        execution.update!(cancel_requested_at: Time.current, cancel_reason: reason.to_s[0, 500])
        EventStore.append!(type: "agent.execution.cancel_requested", aggregate: execution, ticket: execution.ticket, execution: execution,
                           actor: actor, payload: { reason: reason })
        # Not yet picked up by the runtime: cancel immediately.
        transition!(execution, "cancelled", cancel_reason: reason) if execution.status == "queued"
      end
      execution.reload
    end

    # Retries create a new attempt; history is preserved (spec §4).
    def retry!(execution:, actor:)
      raise Error.invalid_transition("Only finished executions can be retried") unless execution.terminal?

      enqueue!(ticket: execution.ticket, provider_key: execution.provider_key, actor: actor, action: execution.action,
               profile: execution.agent_profile, metadata: { "retry_of" => execution.id, "scenario" => execution.metadata["scenario"] }.compact)
    end

    # Resumes the provider session of a finished attempt as a new attempt in the same worktree.
    def resume!(execution:, actor:, message: "Continue the task.")
      raise Error.invalid_transition("Only finished executions can be resumed") unless execution.terminal?

      provider = Providers.registry.fetch(execution.provider_key)
      sid = execution.metadata["provider_session_id"]
      raise UnsupportedCapability.new(:session_resume, provider: execution.provider_key) unless sid && provider.supports?(:session_resume)
      raise Error.workspace_conflict("The worktree of that attempt no longer exists") unless execution.worktree_path && File.directory?(execution.worktree_path)

      enqueue!(ticket: execution.ticket, provider_key: execution.provider_key, action: execution.action, actor: actor, profile: execution.agent_profile,
               metadata: { "resume_of" => execution.id, "provider_session_id" => sid, "resume_message" => message.to_s[0, 4000] })
    end

    # Persists a provider-normalized event with provider_reported provenance.
    def record_provider_event!(execution, normalized)
      payload = normalized.payload.to_h
      if (sid = normalized.external_session_id).present? && execution.metadata["provider_session_id"] != sid
        execution.update_columns(metadata: execution.metadata.merge("provider_session_id" => sid.to_s[0, 128]))
        session = execution.agent_session
        if session && session.external_session_id.nil?
          session.update_columns(external_session_id: sid.to_s[0, 128])
        end
      end
      if (u = normalized.usage)
        UsageRecord.create!(execution: execution, provider_key: execution.provider_key, metering_kind: u.metering_kind || "unknown",
                            input_tokens: u.input_tokens, output_tokens: u.output_tokens,
                            reported_cost: u.reported_cost, currency: u.currency, source: "provider_reported")
      end
      text = payload["text"].to_s
      _, redactions = Redactor.redact_with_count(text)
      EventStore.append!(type: normalized.type, aggregate: execution, ticket: execution.ticket, execution: execution,
                         session: execution.agent_session, source: "provider.#{execution.provider_key}",
                         provenance: normalized.provenance || "provider_reported", payload: payload, topics: [])
      if redactions.positive?
        EventStore.append!(type: "security.secret_redacted", aggregate: execution, ticket: execution.ticket, execution: execution,
                           payload: { where: "provider_output", redactions: redactions })
      end
    end
  end
end
