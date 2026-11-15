module Agentboard
  # Turns a capture from the in-app widget into a ticket plus a `capture` artifact (and an
  # optional `screenshot` artifact). Everything coming from the browser is untrusted: it is
  # bounded, validated and redacted before it is stored or shown to an agent.
  module Captures
    MAX_ELEMENTS = 10
    MAX_SCREENSHOT_BYTES = 3 * 1024 * 1024
    SAFE_PATH = %r{\A[\w./-]{1,300}\z}

    module_function

    def create!(project:, actor:, params:)
      Authorization.authorize!(actor, "ticket.write")
      p = params.to_h.deep_stringify_keys
      title = p["title"].to_s.strip[0, 200]
      raise Error.validation_failed("A title is required") if title.blank?

      kind = p["kind"].to_s.presence_in(Ticket::KINDS) || "bug"
      priority = p["priority"].to_i.clamp(0, 3)
      url = sanitize_url(p["url"])
      elements = Array(p["elements"]).first(MAX_ELEMENTS).map { |e| sanitize_element(e) }
      templates = Array(p["templates"]).map(&:to_s).select { |t| safe_path?(t) }.uniq.first(50)
      console = Array(p["console_errors"]).first(20).map { |c| Redactor.redact(c.to_s)[0, 500] }
      meta = {
        "url" => url, "route" => p["route"].to_s[0, 120].presence, "viewport" => sanitize_viewport(p["viewport"]),
        "user_agent" => p["user_agent"].to_s[0, 300], "elements" => elements, "templates" => templates,
        "console_errors" => console, "captured_by" => actor.label
      }
      expected = p["expected"].to_s.strip[0, 500]
      ticket = nil
      Ticket.transaction do
        ticket = Tickets.create!(project: project, actor: actor, title: title, kind: kind, priority: priority,
                                 description: description_for(p["description"], meta), labels: [ "captured" ],
                                 criteria: expected.present? ? [ expected ] : [], status: expected.present? ? "ready" : "backlog")
        Artifact.create!(ticket: ticket, kind: "capture", uri: url.presence || "capture:#{ticket.key}", title: "Captured from #{meta["route"] || url}",
                         provenance: "confirmed", metadata: meta)
        attach_screenshot!(ticket, p["screenshot"]) if p["screenshot"].present?
        EventStore.append!(type: "ticket.captured", aggregate: ticket, ticket: ticket, actor: actor,
                           payload: { url: url, route: meta["route"], elements: elements.size, templates: templates.size })
      end
      ticket
    end

    def safe_path?(path) = path.match?(SAFE_PATH) && PathGuard.safe_relative?(path)

    def sanitize_url(value)
      uri = URI.parse(value.to_s)
      return nil unless %w[http https].include?(uri.scheme)

      # Query strings often carry tokens; keep only the path for traceability.
      "#{uri.scheme}://#{uri.host}#{":#{uri.port}" if uri.port && ![ 80, 443 ].include?(uri.port)}#{uri.path}"[0, 500]
    rescue URI::InvalidURIError
      nil
    end

    def sanitize_viewport(v)
      v = v.is_a?(Hash) ? v.transform_keys(&:to_s) : {}
      { "width" => v["width"].to_i.clamp(0, 10_000), "height" => v["height"].to_i.clamp(0, 10_000) }
    end

    def sanitize_element(e)
      e = e.is_a?(Hash) ? e.transform_keys(&:to_s) : {}
      rect = e["rect"].is_a?(Hash) ? e["rect"].transform_keys(&:to_s).slice("x", "y", "width", "height").transform_values { |n| n.to_f.round(1) } : {}
      template = e["template"].to_s
      {
        "selector" => e["selector"].to_s[0, 500], "text" => Redactor.redact(e["text"].to_s.squish[0, 300]),
        "html" => Redactor.redact(e["html"].to_s[0, 4000]), "template" => safe_path?(template) ? template : nil, "rect" => rect
      }.compact
    end

    def description_for(text, meta)
      parts = [ Redactor.redact(text.to_s.strip[0, 10_000]).presence ]
      parts << "### Captured from\n- Page: #{meta["url"] || "unknown"}\n- Route: `#{meta["route"] || "unknown"}`\n" \
               "- Viewport: #{meta.dig("viewport", "width")}×#{meta.dig("viewport", "height")}"
      if meta["elements"].any?
        parts << "### Selected elements\n" + meta["elements"].map.with_index(1) do |el, i|
          line = "#{i}. `#{el["selector"]}`"
          line += " — rendered by `#{el["template"]}`" if el["template"]
          line += "\n   “#{el["text"].truncate(160)}”" if el["text"].present?
          line
        end.join("\n")
      end
      parts << "### Templates rendered on this page\n" + meta["templates"].first(20).map { |t| "- `#{t}`" }.join("\n") if meta["templates"].any?
      parts << "### Console errors\n" + meta["console_errors"].map { |c| "- #{c}" }.join("\n") if meta["console_errors"].any?
      parts.compact.join("\n\n")
    end

    def attach_screenshot!(ticket, data_url)
      Agentboard.require_feature!(:capture)
      match = data_url.to_s.match(%r{\Adata:image/png;base64,([A-Za-z0-9+/=]+)\z})
      raise Error.validation_failed("Screenshot must be a PNG data URL") unless match

      bytes = Base64.strict_decode64(match[1])
      raise Error.validation_failed("Screenshot is too large") if bytes.bytesize > MAX_SCREENSHOT_BYTES
      raise Error.validation_failed("Screenshot is not a PNG") unless bytes.start_with?("\x89PNG".b)

      dir = Agentboard.config.root_path.join(".agentboard", "captures")
      FileUtils.mkdir_p(dir, mode: 0o700)
      path = dir.join("#{ticket.key}-#{SecureRandom.hex(4)}.png")
      File.binwrite(path, bytes)
      File.chmod(0o600, path)
      Artifact.create!(ticket: ticket, kind: "screenshot", uri: "file:#{path}", title: "Screenshot of the selected area",
                       sha256: Digest::SHA256.hexdigest(bytes), provenance: "confirmed", metadata: { "bytes" => bytes.bytesize })
    end

    # Paths an agent should look at first for a captured ticket.
    def focus_paths(ticket)
      ticket.artifacts.where(kind: "capture").flat_map do |a|
        Array(a.metadata["elements"]).filter_map { |e| e["template"] } + Array(a.metadata["templates"])
      end.uniq.first(20)
    end
  end
end
