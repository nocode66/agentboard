module Agentboard
  module ApplicationHelper
    # Lucide-style 24px stroke icons, inlined so the dashboard needs no icon font or CDN.
    ICONS = {
      "kanban" => '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M8 7v7"/><path d="M12 7v4"/><path d="M16 7v9"/>',
      "list" => '<path d="M8 6h13"/><path d="M8 12h13"/><path d="M8 18h13"/><path d="M3 6h.01"/><path d="M3 12h.01"/><path d="M3 18h.01"/>',
      "bot" => '<rect x="3" y="11" width="18" height="10" rx="2"/><circle cx="12" cy="5" r="2"/><path d="M12 7v4"/><path d="M8 16h.01"/><path d="M16 16h.01"/>',
      "play" => '<polygon points="6 3 20 12 6 21 6 3"/>',
      "terminal" => '<polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/>',
      "workflow" => '<rect x="3" y="3" width="6" height="6" rx="1"/><rect x="15" y="15" width="6" height="6" rx="1"/><path d="M6 9v3a3 3 0 0 0 3 3h6"/>',
      "chart" => '<path d="M3 3v18h18"/><path d="M7 16v-4"/><path d="M12 16V8"/><path d="M17 16v-7"/>',
      "settings" => '<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>',
      "shield" => '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/>',
      "check" => '<path d="M20 6 9 17l-5-5"/>',
      "x" => '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
      "clock" => '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
      "alert" => '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
      "plus" => '<path d="M5 12h14"/><path d="M12 5v14"/>',
      "search" => '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
      "commit" => '<circle cx="12" cy="12" r="3"/><line x1="3" y1="12" x2="9" y2="12"/><line x1="15" y1="12" x2="21" y2="12"/>',
      "branch" => '<line x1="6" y1="3" x2="6" y2="15"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/>',
      "file" => '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>',
      "link" => '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
      "user" => '<path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>',
      "lock" => '<rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
      "sparkles" => '<path d="M9.94 14.06 8 20l-1.94-5.94L0 12l6.06-1.94L8 4l1.94 6.06L16 12z" transform="translate(3 0) scale(.85)"/><path d="M20 3v4"/><path d="M22 5h-4"/>',
      "chevron" => '<path d="m9 18 6-6-6-6"/>',
      "dot" => '<circle cx="12" cy="12" r="4"/>',
      "refresh" => '<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>',
      "stop" => '<rect x="5" y="5" width="14" height="14" rx="2"/>',
      "sun" => '<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>',
      "moon" => '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>',
      "flask" => '<path d="M10 2v7.31"/><path d="M14 9.3V1.99"/><path d="M8.5 2h7"/><path d="M14 9.3a6.5 6.5 0 1 1-4 0"/><path d="M5.52 16h12.96"/>',
      "eye" => '<path d="M2.06 12.35a1 1 0 0 1 0-.7 10.75 10.75 0 0 1 19.88 0 1 1 0 0 1 0 .7 10.75 10.75 0 0 1-19.88 0"/><circle cx="12" cy="12" r="3"/>',
      "inbox" => '<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
      "pulse" => '<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>',
      "ban" => '<circle cx="12" cy="12" r="10"/><path d="m4.9 4.9 14.2 14.2"/>',
      "edit" => '<path d="M12 20h9"/><path d="M16.38 3.62a1 1 0 0 1 3 3L7.37 18.64a2 2 0 0 1-.86.5l-2.87.84a.5.5 0 0 1-.62-.62l.84-2.87a2 2 0 0 1 .5-.86z"/>',
      "arrow-right" => '<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>',
      "flag" => '<path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"/><line x1="4" y1="22" x2="4" y2="15"/>',
      "layers" => '<path d="m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z"/><path d="m22 17.65-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65"/><path d="m22 12.65-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65"/>'
    }.freeze

    def icon(name, size: 16, klass: nil, stroke: 2)
      body = ICONS.fetch(name.to_s) { ICONS["dot"] }
      tag.svg(body.html_safe, xmlns: "http://www.w3.org/2000/svg", width: size, height: size, viewBox: "0 0 24 24", fill: "none",
                              stroke: "currentColor", "stroke-width": stroke, "stroke-linecap": "round", "stroke-linejoin": "round",
                              class: [ "ab-icon", klass ].compact.join(" "), "aria-hidden": "true")
    end

    STATUS_ICON = {
      "backlog" => "dot", "ready" => "dot", "claimed" => "lock", "in_progress" => "pulse", "testing" => "flask",
      "review" => "eye", "done" => "check", "blocked" => "ban", "cancelled" => "x", "reopened" => "refresh"
    }.freeze

    def status_pill(status, label: nil)
      tag.span(class: "pill pill-#{status.to_s.tr("_", "-")}") do
        safe_join([ tag.span(class: "pill-dot"), label || StateMachines::Ticket::LABELS[status.to_s] || status.to_s.humanize ])
      end
    end

    def status_glyph(status)
      tag.span(class: "status-glyph sg-#{status.to_s.tr("_", "-")}", title: StateMachines::Ticket::LABELS[status.to_s])
    end

    def execution_pill(status)
      tag.span(class: "pill pill-exec-#{status.to_s.tr("_", "-")}") do
        safe_join([ tag.span(class: "pill-dot#{StateMachines::Execution::ACTIVE.include?(status.to_s) && status.to_s != "queued" ? " pill-dot-live" : ""}"),
                    status.to_s.humanize ])
      end
    end

    def priority_icon(priority)
      label = Ticket::PRIORITIES[priority]
      if priority.to_i.zero?
        return tag.span(class: "prio prio-urgent", title: label) { "!" }
      end

      bars = 4 - priority.to_i
      tag.span(class: "prio prio-#{priority}", title: label) do
        safe_join((1..3).map { |i| tag.i(class: i <= bars ? "on" : nil, style: "height:#{3 + i * 3}px") })
      end
    end

    def kind_badge(kind)
      tag.span(kind, class: "kind kind-#{kind}")
    end

    PROVENANCE_SHORT = { "confirmed" => "AgentBoard", "provider_reported" => "Provider", "git_observed" => "Git", "inferred" => "Inferred" }.freeze

    def provenance_badge(provenance)
      tag.span(PROVENANCE_SHORT.fetch(provenance.to_s, provenance.to_s), class: "prov prov-#{provenance.to_s.tr("_", "-")}",
                                                                         title: Event::PROVENANCE_LABELS[provenance.to_s])
    end

    def avatar(name, kind: "human", size: 22)
      initials = name.to_s.scan(/[A-Za-z0-9]+/).first(2).map { |w| w[0] }.join.upcase.presence || "?"
      hue = Digest::MD5.hexdigest(name.to_s)[0, 2].to_i(16) * 360 / 255
      tag.span(kind == "agent" ? icon("bot", size: (size * 0.6).round) : initials,
               class: "avatar avatar-#{kind}", title: name, style: "--h:#{hue};width:#{size}px;height:#{size}px")
    end

    def provider_avatar(provider_key, size: 22)
      tag.span(provider_key.to_s[0, 2].capitalize, class: "avatar avatar-provider prov-key-#{provider_key}", title: provider_key.to_s, style: "width:#{size}px;height:#{size}px")
    end

    def ago(time)
      return "—" unless time

      tag.time(time_ago_in_words(time) + " ago", datetime: time.utc.iso8601, title: time.utc.strftime("%Y-%m-%d %H:%M:%S UTC"))
    end

    def duration(seconds)
      return "—" unless seconds

      s = seconds.to_i
      return "#{s}s" if s < 60
      return "#{s / 60}m #{s % 60}s" if s < 3600

      "#{s / 3600}h #{(s % 3600) / 60}m"
    end

    def short_sha(sha) = sha.to_s.start_with?("unbound:") ? "unbound" : sha.to_s[0, 8]

    def sha_tag(sha)
      return tag.span("—", class: "muted") if sha.blank?

      tag.code(short_sha(sha), class: "sha", title: sha)
    end

    def meter(done, total, klass: nil)
      pct = total.to_i.zero? ? 0 : (done * 100.0 / total).round
      tag.span(class: [ "meter", klass ].compact.join(" "), title: "#{done}/#{total}") { tag.span(style: "width:#{pct}%") }
    end

    def nav_link(label, path, icon_name, active:, count: nil, kbd: nil)
      link_to(path, class: "nav-item#{active ? " is-active" : ""}") do
        safe_join([ icon(icon_name, size: 16), tag.span(label, class: "nav-label"),
                    (count.to_i.positive? ? tag.span(count, class: "nav-count") : nil),
                    (kbd ? tag.kbd(kbd, class: "nav-kbd") : nil) ].compact)
      end
    end

    def event_title(event)
      p = event.data || {}
      case event.event_type
      when "ticket.created" then "created the ticket"
      when "ticket.transitioned" then safe_join([ "moved ", status_pill(p["from"]), " → ", status_pill(p["to"]) ])
      when "ticket.claimed" then "claimed the ticket (fencing ##{p["fencing_token"]})"
      when "ticket.lease_released" then "released the lease (#{p["reason"]})"
      when "ticket.commented" then "commented"
      when "ticket.progress" then safe_join([ "progress", p["percent"] ? " · #{p["percent"]}%" : "", p["phase"] ? " · #{p["phase"]}" : "", ": ", p["message"].to_s ])
      when "ticket.updated" then "updated #{(p["changes"] || {}).keys.join(", ")}"
      when "git.commit_attached" then safe_join([ "attached commit ", sha_tag(p["commit_sha"]), p["verified_in_repo"] ? "" : " (not found in repository)" ])
      when "git.snapshot" then safe_join([ "snapshot ", sha_tag(p["head_sha"]), " · #{Array(p["files"]).size} files" ])
      when "git.worktree_created" then safe_join([ "created worktree on ", tag.code(p["branch"]) ])
      when "verification.passed" then safe_join([ "✓ ", tag.strong(p["name"]), " passed at ", sha_tag(p["commit_sha"]) ])
      when "verification.failed" then safe_join([ "✗ ", tag.strong(p["name"]), " #{p["status"]} at ", sha_tag(p["commit_sha"]) ])
      when "approval.requested" then "requested approval: #{p["action_kind"].to_s.humanize}"
      when /\Aapproval\.(approved|rejected|invalidated)\z/ then "approval #{$1}"
      when "agent.session.attached" then "session attached via #{p["source"]}#{p["confidence"] == "needs_confirmation" ? " (needs confirmation)" : ""}"
      when "agent.execution.message" then p["text"].to_s.truncate(240)
      when "agent.tool.started" then safe_join([ "→ ", tag.code(p["tool"].to_s), " ", p["target"].to_s ])
      when "agent.tool.completed" then safe_join([ "✓ ", tag.code(p["tool"].to_s), " ", p["target"].to_s, Array(p["files"]).first(3).join(", ") ])
      when "security.secret_redacted" then "redacted #{p["redactions"]} secret(s) from #{p["where"]}"
      when /\Aagent\.execution\.(\w+)\z/ then "execution #{$1.humanize.downcase}#{p["reason"] ? " — #{p["reason"]}" : ""}"
      when /\Aworkflow\.(.+)\z/ then "workflow #{$1.tr("_", " ")}#{p["step"] ? " · #{p["step"]}" : ""}"
      else event.event_type
      end
    end

    def event_icon(event)
      case event.event_type
      when /\Averification\.passed/ then [ "check", "ok" ]
      when /\Averification\.failed|failed|rejected|denied/ then [ "x", "bad" ]
      when /\Agit\./ then [ "commit", "git" ]
      when /\Aapproval\./ then [ "shield", "approval" ]
      when /\Aagent\.tool/ then [ "terminal", "tool" ]
      when /\Aagent\./ then [ "bot", "agent" ]
      when /\Asecurity\./ then [ "lock", "bad" ]
      when /commented/ then [ "edit", "comment" ]
      else [ "dot", "neutral" ]
      end
    end

    def actor_label(event)
      return event.source.sub("provider.", "") if event.actor_type.nil?

      event.actor_type == "agent" ? "agent" : event.actor_id
    end

    def asset_url(name)
      engine_asset_path(name: name, v: AssetsController.fingerprint(name))
    end
  end
end
