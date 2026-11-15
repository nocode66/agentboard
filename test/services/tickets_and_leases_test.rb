require "test_helper"

class TicketsAndLeasesTest < ActiveSupport::TestCase
  test "tickets get sequential project keys and emit events" do
    a = create_ticket(title: "One")
    b = create_ticket(title: "Two")
    assert_equal "AB-1", a.key
    assert_equal "AB-2", b.key
    assert_equal b, Agentboard::Ticket.find_by_key!("ab-2")
    assert_includes a.events.pluck(:event_type), "ticket.created"
  end

  test "backlog -> ready needs criteria or a human override with reason" do
    t = create_ticket(criteria: [], status: "backlog")
    assert_error_code("POLICY_DENIED") { Agentboard::Tickets.transition!(ticket: t, to: "ready", actor: human) }
    Agentboard::Tickets.transition!(ticket: t, to: "ready", actor: human, override_criteria: true, reason: "spike")
    assert_equal "ready", t.reload.status
  end

  test "unspecified transitions are rejected" do
    t = create_ticket
    assert_error_code("INVALID_TRANSITION") { Agentboard::Tickets.transition!(ticket: t, to: "review", actor: human) }
  end

  test "blocked requires a reason and blocked -> ready needs finished dependencies" do
    dep = create_ticket(title: "dep")
    t = create_ticket
    Agentboard::Tickets.add_dependency!(ticket: t, depends_on: dep, actor: human)
    assert_error_code("VALIDATION_FAILED") { Agentboard::Tickets.transition!(ticket: t, to: "blocked", actor: human) }
    Agentboard::Tickets.transition!(ticket: t, to: "blocked", actor: human, reason: "waiting")
    assert_error_code("POLICY_DENIED") { Agentboard::Tickets.transition!(ticket: t, to: "ready", actor: human) }
  end

  test "dependency cycles are rejected" do
    a = create_ticket(title: "a")
    b = create_ticket(title: "b")
    Agentboard::Tickets.add_dependency!(ticket: a, depends_on: b, actor: human)
    assert_raises(ActiveRecord::RecordInvalid) { Agentboard::Tickets.add_dependency!(ticket: b, depends_on: a, actor: human) }
  end

  test "AT-04: exactly one concurrent claim succeeds" do
    t = create_ticket
    sessions = 2.times.map { agent_session }
    results = Queue.new
    threads = sessions.map do |s|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Agentboard::LeaseService.claim!(ticket: Agentboard::Ticket.find(t.id), actor: s.actor, session: s)
          results << :ok
        rescue Agentboard::Error => e
          results << e.code
        rescue ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid
          results << "LEASE_CONFLICT"
        end
      end
    end
    threads.each(&:join)
    outcomes = 2.times.map { results.pop }
    assert_equal 1, outcomes.count(:ok), outcomes.inspect
    assert_equal 1, (outcomes - [ :ok ]).size
    assert_equal 1, t.leases.live.count
  end

  test "expired lease cannot mutate the ticket (LEASE_EXPIRED) and fencing supersedes stale tokens" do
    t = create_ticket
    s = agent_session
    claim = Agentboard::LeaseService.claim!(ticket: t, actor: s.actor, session: s, lease_seconds: 30)
    claim.lease.update!(expires_at: 1.second.ago)
    assert_error_code("LEASE_EXPIRED") { Agentboard::LeaseService.validate!(ticket: t, token: claim.token, session: s) }

    # Ticket is reclaimable once released back to ready; the old token stays dead.
    Agentboard::LeaseService.expire_stale!(t)
    t.update!(status: "ready")
    s2 = agent_session
    claim2 = Agentboard::LeaseService.claim!(ticket: t.reload, actor: s2.actor, session: s2)
    assert_operator claim2.lease.fencing_token, :>, claim.lease.fencing_token
    assert_error_code("LEASE_EXPIRED") { Agentboard::LeaseService.validate!(ticket: t, token: claim.token) }
  end

  test "a session cannot use another session's lease token" do
    t = create_ticket
    owner = agent_session
    thief = agent_session
    claim = Agentboard::LeaseService.claim!(ticket: t, actor: owner.actor, session: owner)
    assert_error_code("UNAUTHORIZED") { Agentboard::LeaseService.validate!(ticket: t, token: claim.token, session: thief) }
    assert_error_code("UNAUTHORIZED") do
      Agentboard::Tickets.transition!(ticket: t, to: "blocked", reason: "x", actor: thief.actor, session: thief, lease_token: claim.token)
    end
  end

  test "agents cannot cancel or reopen tickets" do
    t = create_ticket
    s = agent_session
    assert_error_code("FORBIDDEN") { Agentboard::Tickets.transition!(ticket: t, to: "cancelled", reason: "no", actor: s.actor) }
  end

  test "comments are redacted and flagged" do
    t = create_ticket
    c = Agentboard::Tickets.add_comment!(ticket: t, actor: human, body: "token ghp_abcdefghijklmnopqrstuvwxyz0123456789")
    refute_includes c.body, "ghp_"
    assert t.events.where(event_type: "security.secret_redacted").exists?
  end
end

class EventStoreTest < ActiveSupport::TestCase
  test "sequences per aggregate, outbox rows in the same transaction, dedupe on replay" do
    t = create_ticket
    e1 = Agentboard::EventStore.append!(type: "ticket.progress", aggregate: t, ticket: t, dedupe_key: "k1")
    e2 = Agentboard::EventStore.append!(type: "ticket.progress", aggregate: t, ticket: t, dedupe_key: "k1")
    assert_equal e1.id, e2.id
    seqs = Agentboard::Event.where(aggregate_type: "ticket", aggregate_id: t.id).order(:sequence).pluck(:sequence)
    assert_equal (1..seqs.size).to_a, seqs
    assert Agentboard::OutboxMessage.where(event_id: e1.id, topic: "projections").exists?
    assert_raises(ActiveRecord::ReadOnlyRecord) { e1.update!(source: "x") }
  end

  test "outbox delivers at least once with retries and dead letters" do
    t = create_ticket
    calls = 0
    Agentboard::Outbox.reset!
    Agentboard::Outbox.subscribe("projections") { |_e| calls += 1 }
    assert_operator Agentboard::Outbox.drain, :>, 0
    assert_operator calls, :>, 0
    Agentboard::Outbox.reset!
    Agentboard::Outbox.subscribe("projections") { |_e| raise "boom" }
    Agentboard::EventStore.append!(type: "ticket.progress", aggregate: t, ticket: t)
    Agentboard::Outbox.drain
    msg = Agentboard::OutboxMessage.order(:created_at).last
    assert_equal "pending", msg.state
    assert_equal 1, msg.attempts
    assert_match(/boom/, msg.last_error)
  ensure
    Agentboard::Outbox.reset!
  end

  test "idempotency returns stored response and rejects key reuse with a different request" do
    n = 0
    r1 = Agentboard::Idempotency.call(scope: "s", key: "k", request: { a: 1 }) { n += 1; { "v" => n } }
    r2 = Agentboard::Idempotency.call(scope: "s", key: "k", request: { a: 1 }) { n += 1; { "v" => n } }
    assert_equal r1, r2
    assert_equal 1, n
    assert_error_code("VALIDATION_FAILED") { Agentboard::Idempotency.call(scope: "s", key: "k", request: { a: 2 }) { {} } }
  end
end
