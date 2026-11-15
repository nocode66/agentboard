module Agentboard
  # MCP tool contracts (spec §6, §25). Every tool:
  # - validates input against a strict JSON Schema (additionalProperties: false)
  # - acts as the MCP process's own trusted session (client-supplied session ids are labels)
  # - is individually authorized and logged with a correlation id
  # - returns the standard result envelope; failures set isError
  class McpTools
    KEY = { "type" => "string", "pattern" => "^[A-Z][A-Z0-9_-]*-[0-9]+$", "description" => "Ticket key, e.g. AB-142" }.freeze
    TOKEN = { "type" => "string", "minLength" => 16, "maxLength" => 200, "description" => "Bearer lease token returned by claim_ticket" }.freeze
    SHA = { "type" => "string", "pattern" => "^[0-9a-fA-F]{7,64}$" }.freeze
    WRITE_LIMIT_PER_MINUTE = 120

    def self.schema(required: [], **props)
      { "type" => "object", "additionalProperties" => false, "required" => required.map(&:to_s), "properties" => props.transform_keys(&:to_s) }
    end

    DEFINITIONS = {
      "list_tickets" => [ "Filter tickets in the current project",
                          schema(status: { "type" => "string", "enum" => StateMachines::Ticket::STATES },
                                 priority: { "type" => "integer", "minimum" => 0, "maximum" => 3 },
                                 limit: { "type" => "integer", "minimum" => 1, "maximum" => 100 },
                                 cursor: { "type" => "string", "maxLength" => 64 }), false ],
      "get_ticket" => [ "Read a ticket with acceptance criteria, dependencies and version",
                        schema(required: [ :ticket_key ], ticket_key: KEY, include_history: { "type" => "boolean" }), false ],
      "get_next_ticket" => [ "Find the highest-priority ready ticket whose dependencies are done", schema, false ],
      "claim_ticket" => [ "Acquire an exclusive, expiring lease for a ticket",
                          schema(required: %i[ticket_key expected_version], ticket_key: KEY,
                                 expected_version: { "type" => "integer", "minimum" => 0 },
                                 lease_seconds: { "type" => "integer", "minimum" => 30, "maximum" => 3600 }), true ],
      "release_ticket" => [ "Release a lease you hold", schema(required: %i[ticket_key lease_token], ticket_key: KEY, lease_token: TOKEN,
                                                             reason: { "type" => "string", "maxLength" => 500 }), true ],
      "heartbeat_lease" => [ "Extend a lease you hold", schema(required: %i[ticket_key lease_token], ticket_key: KEY, lease_token: TOKEN,
                                                             lease_seconds: { "type" => "integer", "minimum" => 30, "maximum" => 3600 }), true ],
      "start_work" => [ "Bind this session to the ticket and move it to in_progress",
                        schema(required: %i[ticket_key lease_token], ticket_key: KEY, lease_token: TOKEN, summary: { "type" => "string", "maxLength" => 2000 }), true ],
      "update_progress" => [ "Record structured progress", schema(required: %i[ticket_key lease_token message], ticket_key: KEY, lease_token: TOKEN,
                                                                  message: { "type" => "string", "minLength" => 1, "maxLength" => 4000 },
                                                                  phase: { "type" => "string", "enum" => %w[planning implementing testing reviewing documenting] },
                                                                  percent: { "type" => "integer", "minimum" => 0, "maximum" => 100 }), true ],
      "add_comment" => [ "Comment on a ticket", schema(required: %i[ticket_key body], ticket_key: KEY, body: { "type" => "string", "minLength" => 1, "maxLength" => 10_000 },
                                                        visibility: { "type" => "string", "enum" => %w[team private] }), true ],
      "report_blocker" => [ "Record a blocker and move the ticket to blocked",
                            schema(required: %i[ticket_key lease_token reason], ticket_key: KEY, lease_token: TOKEN,
                                   reason: { "type" => "string", "minLength" => 3, "maxLength" => 2000 },
                                   category: { "type" => "string", "enum" => %w[dependency question environment permission other] }), true ],
      "get_project_context" => [ "Bounded repository context for the current project",
                                 schema(ticket_key: KEY, paths: { "type" => "array", "items" => { "type" => "string", "maxLength" => 300 }, "maxItems" => 20 },
                                        budget_tokens: { "type" => "integer", "minimum" => 1000, "maximum" => 50_000 }), false ],
      "get_acceptance_criteria" => [ "Verification requirements for a ticket", schema(required: [ :ticket_key ], ticket_key: KEY), false ],
      "attach_commit" => [ "Link a commit to a ticket (verified against the repository)",
                           schema(required: %i[ticket_key commit_sha], ticket_key: KEY, commit_sha: SHA, lease_token: TOKEN), true ],
      "attach_artifact" => [ "Link an output (log, report, link) to a ticket",
                             schema(required: %i[ticket_key kind uri], ticket_key: KEY, lease_token: TOKEN,
                                    kind: { "type" => "string", "enum" => Artifact::KINDS - [ "commit" ] },
                                    uri: { "type" => "string", "maxLength" => 2000 }, title: { "type" => "string", "maxLength" => 255 }), true ],
      "submit_for_review" => [ "Request review for a specific head commit; required checks must have passed for it",
                               schema(required: %i[ticket_key lease_token head_sha], ticket_key: KEY, lease_token: TOKEN, head_sha: SHA,
                                      summary: { "type" => "string", "maxLength" => 4000 }), true ],
      "request_approval" => [ "Ask a human to authorize a privileged action",
                              schema(required: %i[action_kind action_digest reason], action_kind: { "type" => "string", "enum" => Approval::ACTION_KINDS },
                                     action_digest: { "type" => "string", "pattern" => "^[0-9a-f]{64}$" }, reason: { "type" => "string", "maxLength" => 2000 },
                                     ticket_key: KEY, execution_id: { "type" => "string", "maxLength" => 36 }), true ],
      "complete_ticket" => [ "Request policy-controlled completion; returns POLICY_DENIED with missing evidence when gates are not met",
                             schema(required: %i[ticket_key expected_version], ticket_key: KEY, expected_version: { "type" => "integer", "minimum" => 0 },
                                    lease_token: TOKEN, evidence_ids: { "type" => "array", "items" => { "type" => "string", "maxLength" => 36 }, "maxItems" => 50 }), true ],
      # Permission prompt tool for execution-bound sessions (Claude Code --permission-prompt-tool).
      # The provider defines the request shape, so extra properties are tolerated here.
      "permission_prompt" => [ "Ask a human (via AgentBoard approvals) whether the agent may use a tool",
                               { "type" => "object", "additionalProperties" => true, "required" => %w[tool_name],
                                 "properties" => { "tool_name" => { "type" => "string", "maxLength" => 200 }, "input" => { "type" => "object" },
                                                   "tool_use_id" => { "type" => "string", "maxLength" => 200 } } }, true ]
    }.freeze

    # Tools exposed to an AgentBoard-launched agent: it already runs under the runtime's lease,
    # so it only gets read access plus the permission bridge.
    EXECUTION_TOOLS = %w[get_ticket get_acceptance_criteria get_project_context permission_prompt].freeze
    PERMISSION_POLL_SECONDS = 1

    attr_reader :project, :session

    attr_reader :execution

    def initialize(project:, session:, execution: nil, credential: nil)
      @project = project
      @session = session
      @execution = execution
      @credential = credential
      @writes = []
    end

    def tool_names = execution ? EXECUTION_TOOLS : (DEFINITIONS.keys - [ "permission_prompt" ])

    def actor = session.actor

    def call(name, args)
      args = args.transform_keys(&:to_s)
      _desc, _schema, write = DEFINITIONS.fetch(name)
      correlation = Ids.correlation
      unless tool_names.include?(name)
        return Result.failure(Error.forbidden("Tool #{name} is not available to this session"), correlation_id: correlation)
      end
      Current.correlation_id = correlation
      result = Result.capture(correlation_id: correlation) do
        @credential = SessionCredential.verify!(session, @credential) if @credential || !execution
        rate_limit! if write
        session.touch_seen!
        public_send("tool_#{name}", args)
      end
      Agentboard.logger.info("[agentboard.mcp] #{correlation} session=#{session.id[0, 8]} tool=#{name} ok=#{result.ok?}#{result.ok? ? "" : " code=#{result.error.code}"}")
      if !result.ok? && %w[FORBIDDEN UNAUTHORIZED POLICY_DENIED].include?(result.error.code)
        EventStore.append!(type: "security.mcp_denied", aggregate: session, project: project, session: session, actor: actor,
                           payload: { tool: name, code: result.error.code }) rescue nil
      end
      result
    end

    # -- read tools -----------------------------------------------------------------
    def tool_list_tickets(a)
      scope = project.tickets.includes(:project).ordered
      scope = scope.where(status: a["status"]) if a["status"]
      scope = scope.where(priority: a["priority"]) if a["priority"]
      limit = (a["limit"] || 25).to_i
      offset = a["cursor"].to_s.match?(/\A\d+\z/) ? a["cursor"].to_i : 0
      rows = scope.offset(offset).limit(limit + 1).to_a
      { tickets: rows.first(limit).map { |t| summary(t) }, next_cursor: rows.size > limit ? (offset + limit).to_s : nil }
    end

    def tool_get_ticket(a)
      t = ticket!(a)
      data = { ticket: detail(t), criteria: criteria(t), dependencies: t.depends_on.map { |d| { key: d.key, status: d.status } }, version: t.lock_version }
      data[:history] = t.events.last(50).map { |e| e.envelope.slice(:type, :provenance, :occurred_at, :payload) } if a["include_history"]
      data
    end

    def tool_get_next_ticket(_a)
      t = project.tickets.where(status: "ready").ordered.includes(:depends_on).find(&:dependencies_satisfied?)
      { ticket: t && summary(t).merge(version: t.lock_version) }
    end

    def tool_get_acceptance_criteria(a)
      t = ticket!(a)
      { ticket_key: t.key, criteria: criteria(t), required_checks: Agentboard.config.verification_catalog.required_names }
    end

    def tool_get_project_context(a)
      t = a["ticket_key"] ? ticket!(a) : nil
      repo = project.repository
      if t
        pkg = ContextBuilder.call(ticket: t, repository: repo, max_tokens: (a["budget_tokens"] || 8000).to_i)
        { context: pkg.text, snapshot_sha: pkg.base_sha, truncated: pkg.truncated, files: pkg.files }
      else
        paths = Array(a["paths"]).select { |p| PathGuard.safe_relative?(p) }
        files = paths.filter_map do |p|
          full = PathGuard.within!(repo.root, p)
          next unless File.file?(full)

          { path: p, content: Redactor.redact(File.binread(full, 20_000).force_encoding("UTF-8").scrub) }
        end
        { context: { project: project.name, key: project.key, default_branch: project.default_branch, files: files,
                     recent_commits: repo.log(limit: 10) }, snapshot_sha: repo.head_sha, truncated: false }
      end
    end

    # -- write tools ----------------------------------------------------------------
    def tool_claim_ticket(a)
      t = ticket!(a)
      claim = LeaseService.claim!(ticket: t, actor: actor, session: session, lease_seconds: a["lease_seconds"], expected_version: a["expected_version"])
      { lease_token: claim.token, fencing_token: claim.lease.fencing_token, expires_at: claim.lease.expires_at.utc.iso8601, ticket: summary(t.reload) }
    end

    def tool_release_ticket(a)
      t = ticket!(a)
      LeaseService.release!(ticket: t, token: a["lease_token"], actor: actor, session: session, reason: a["reason"] || "released by agent")
      SessionAssociation.unlink!(session: session, actor: actor)
      { released: true, status: t.reload.status }
    end

    def tool_heartbeat_lease(a)
      t = ticket!(a)
      lease = LeaseService.heartbeat!(ticket: t, token: a["lease_token"], session: session, lease_seconds: a["lease_seconds"])
      { expires_at: lease.expires_at.utc.iso8601 }
    end

    def tool_start_work(a)
      t = ticket!(a)
      LeaseService.validate!(ticket: t, token: a["lease_token"], session: session)
      link = SessionAssociation.link!(session: session, ticket: t, source: "mcp", actor: actor)
      SessionCorrelation.propagate_link!(session)
      Tickets.transition!(ticket: t, to: "in_progress", actor: actor, lease_token: a["lease_token"], session: session) if t.status == "claimed"
      Tickets.add_comment!(ticket: t, actor: actor, body: a["summary"]) if a["summary"].present?
      { session_link_id: link.id, status: t.reload.status }
    end

    def tool_update_progress(a)
      t = ticket!(a)
      LeaseService.validate!(ticket: t, token: a["lease_token"], session: session)
      e = EventStore.append!(type: "ticket.progress", aggregate: t, ticket: t, actor: actor, session: session, provenance: "provider_reported",
                             payload: { message: a["message"], phase: a["phase"], percent: a["percent"] }.compact)
      { event_id: e.id }
    end

    def tool_add_comment(a)
      t = ticket!(a)
      c = Tickets.add_comment!(ticket: t, actor: actor, body: a["body"], visibility: a["visibility"] || "team")
      { comment_id: c.id }
    end

    def tool_report_blocker(a)
      t = ticket!(a)
      reason = "[#{a["category"] || "other"}] #{a["reason"]}"
      Tickets.transition!(ticket: t, to: "blocked", actor: actor, reason: reason, lease_token: a["lease_token"], session: session)
      { status: "blocked", event_id: t.events.last&.id }
    end

    def tool_attach_commit(a)
      t = ticket!(a)
      LeaseService.validate!(ticket: t, token: a["lease_token"], session: session) if a["lease_token"]
      artifact = Evidence.attach_commit!(ticket: t, commit_sha: a["commit_sha"], actor: actor, session: session)
      Approvals.invalidate_stale!(ticket: t, head_sha: artifact.commit_sha) if artifact.metadata["verified_in_repo"]
      { artifact_id: artifact.id, verified_in_repo: artifact.metadata["verified_in_repo"] }
    end

    def tool_attach_artifact(a)
      t = ticket!(a)
      LeaseService.validate!(ticket: t, token: a["lease_token"], session: session) if a["lease_token"]
      artifact = Evidence.attach_artifact!(ticket: t, actor: actor, kind: a["kind"], uri: a["uri"], title: a["title"], session: session)
      { artifact_id: artifact.id }
    end

    def tool_submit_for_review(a)
      t = ticket!(a)
      LeaseService.validate!(ticket: t, token: a["lease_token"], session: session)
      head = project.repository.resolve_commit(a["head_sha"]) or raise Error.validation_failed("head_sha is not a commit in this repository")
      unless t.artifacts.where(kind: "commit", commit_sha: head).exists?
        Evidence.attach_commit!(ticket: t, commit_sha: head, actor: actor, session: session)
      end
      if t.status == "in_progress"
        Tickets.transition!(ticket: t, to: "testing", actor: actor, lease_token: a["lease_token"], session: session)
      end
      report = CompletionPolicy.checks_report(t, head_sha: head)
      unless report[:ok]
        raise Error.policy_denied("Required checks have not passed for #{head[0, 10]}. Ask a human to run `agentboard verify #{t.key}`.",
                                  missing: report[:missing], status: t.reload.status)
      end
      Tickets.transition!(ticket: t, to: "review", actor: actor, lease_token: a["lease_token"], session: session, head_sha: head)
      approval = Approvals.request_review!(ticket: t, actor: actor, head_sha: head, summary: a["summary"])
      { review_request_id: approval.id, status: t.reload.status }
    end

    def tool_request_approval(a)
      t = a["ticket_key"] ? ticket!(a) : nil
      execution = a["execution_id"] && Execution.joins(:ticket).where(agentboard_tickets: { project_id: project.id }).find_by(id: a["execution_id"])
      approval = Approvals.request!(project: project, ticket: t, execution: execution, actor: actor, action_kind: a["action_kind"],
                                    action_digest: a["action_digest"], reason: a["reason"], head_sha: t && Evidence.head_sha(t))
      { approval_id: approval.id, status: approval.decision }
    end

    def tool_complete_ticket(a)
      t = ticket!(a)
      # Agent-supplied evidence ids are only accepted if they are persisted records of this ticket.
      bad = Array(a["evidence_ids"]).reject { |id| Artifact.where(id: id, ticket_id: t.id).exists? || VerificationResult.where(id: id, ticket_id: t.id).exists? }
      raise Error.validation_failed("Unknown evidence ids: #{bad.join(", ")}") if bad.any?

      CompletionPolicy.complete!(ticket: t, actor: actor, expected_version: a["expected_version"], lease_token: a["lease_token"], session: session)
      { status: t.reload.status }
    end

    # Blocks until a human decides (or the request times out). Returns the provider's decision
    # shape: { behavior: "allow", updatedInput: … } or { behavior: "deny", message: … }.
    def tool_permission_prompt(a)
      raise Error.forbidden("permission_prompt is only available to AgentBoard-launched executions") unless execution

      exec = Execution.find(execution.id)
      return deny("Execution is no longer active") if exec.terminal?

      # MCP transports symbolize nested keys; normalize so policies and summaries see "command".
      input = a["input"].is_a?(Hash) ? a["input"].deep_stringify_keys : {}
      decision = CommandPolicy.classify(a["tool_name"], input)
      summary = Redactor.redact(CommandPolicy.summarize(a["tool_name"], input))
      if decision.verdict == :deny
        EventStore.append!(type: "security.permission_denied_by_policy", aggregate: exec, ticket: exec.ticket, execution: exec, session: session,
                           payload: { tool: a["tool_name"], summary: summary[0, 300], reason: decision.reason })
        return deny("Denied by AgentBoard policy: #{decision.reason}")
      end

      timeout = Agentboard.config.runtime.fetch("permission_timeout_seconds", 600).to_i
      approval = Approvals.request!(project: project, ticket: exec.ticket, execution: exec, actor: actor, action_kind: decision.action_kind,
                                    action_payload: { tool_name: a["tool_name"].to_s[0, 200], summary: summary[0, 1000], tool_use_id: a["tool_use_id"].to_s[0, 200] },
                                    reason: "#{exec.provider_key} wants to use #{a["tool_name"]}: #{summary[0, 400]}", ttl: timeout.seconds)
      set_waiting(exec, true)
      deadline = Subprocess.monotonic + timeout
      approval.reload while approval.pending? && Subprocess.monotonic < deadline && !Execution.find(exec.id).terminal? && sleep(PERMISSION_POLL_SECONDS)
      set_waiting(exec, false)
      if approval.reload.decision == "approved"
        { behavior: "allow", updatedInput: input }
      else
        Approval.where(id: approval.id, decision: "pending").update_all(decision: "expired", updated_at: Time.current)
        deny(approval.decision_reason.presence || "Not approved (#{approval.reload.decision})")
      end
    end

    private

    def deny(message) = { behavior: "deny", message: message.to_s[0, 500] }

    def set_waiting(exec, waiting)
      exec.reload
      if waiting && exec.status == "running"
        Executions.transition!(exec, "waiting_for_permission")
      elsif !waiting && exec.status == "waiting_for_permission" && Approval.pending.where(execution_id: exec.id).none?
        Executions.transition!(exec, "running")
      end
    rescue Agentboard::Error
      nil
    end

    def ticket!(a) = Ticket.find_by_key!(a.fetch("ticket_key"), project: project)

    def rate_limit!
      now = Subprocess.monotonic
      @writes.reject! { |t| now - t > 60 }
      raise Error.rate_limited("Too many write operations; slow down") if @writes.size >= WRITE_LIMIT_PER_MINUTE

      @writes << now
    end

    def summary(t)
      { key: t.key, title: t.title, status: t.status, priority: t.priority, kind: t.kind, labels: t.labels }
    end

    def detail(t)
      summary(t).merge(description: Redactor.redact(t.description), version: t.lock_version, blocked_reason: t.blocked_reason,
                       lease: t.active_lease && { holder: t.active_lease.holder_label, expires_at: t.active_lease.expires_at.utc.iso8601,
                                                  yours: t.active_lease.agent_session_id == session.id })
    end

    def criteria(t)
      t.acceptance_criteria.map { |c| { id: c.id, position: c.position, description: c.description, verification_kind: c.verification_kind, status: c.state } }
    end
  end
end
