module Agentboard
  # Drafting assistance (spec §10): deterministic suggestions that a human must accept.
  # Nothing here mutates a ticket; accepting goes through the normal Tickets services.
  module TicketAdvisor
    Suggestion = Struct.new(:kind, :text, :value, :reason, keyword_init: true)

    CRITERIA_TEMPLATES = {
      "bug" => [ "A regression test reproduces the bug and passes with the fix", "Root cause is described in the PR or a comment" ],
      "feature" => [ "Automated tests cover the new behaviour", "User-facing changes are documented" ],
      "task" => [ "The change is covered by existing or new tests" ],
      "chore" => [ "The full test suite passes" ],
      "spike" => [ "Findings and a recommendation are written up as a comment" ]
    }.freeze

    module_function

    def suggest(ticket)
      builder = ContextBuilder.new(ticket: ticket, repository: ticket.project.repository, max_tokens: 2_000, chdir: nil, action: "advise", handoff: nil)
      files = builder.relevant_files(limit: 8)
      suggestions = []
      files.each { |path, score| suggestions << Suggestion.new(kind: "file", text: path, value: path, reason: "keyword match score #{score}") }
      suggestions << complexity(ticket, files)
      existing = ticket.acceptance_criteria.map { |c| c.description.downcase }
      CRITERIA_TEMPLATES.fetch(ticket.kind, []).reject { |c| existing.include?(c.downcase) }.each do |c|
        suggestions << Suggestion.new(kind: "criterion", text: c, value: c, reason: "common for #{ticket.kind} tickets")
      end
      subtasks(ticket).each { |s| suggestions << Suggestion.new(kind: "subtask", text: s, value: s, reason: "listed in the description") }
      dependencies(ticket, builder, files).each { |t, why| suggestions << Suggestion.new(kind: "dependency", text: "#{t.key} — #{t.title}", value: t.key, reason: why) }
      suggestions
    end

    def complexity(ticket, files)
      score = files.size + ticket.description.to_s.scan(/\S+/).size / 80 + ticket.acceptance_criteria.size
      size = score <= 3 ? "S" : (score <= 7 ? "M" : "L")
      Suggestion.new(kind: "complexity", text: size, value: size, reason: "#{files.size} relevant files, #{ticket.acceptance_criteria.size} criteria")
    end

    # Bullet or numbered lines in the description become subtask candidates.
    def subtasks(ticket)
      existing = ticket.subtasks.pluck(:title).map(&:downcase)
      ticket.description.to_s.lines.map(&:chomp).filter_map { |l| l[/\A\s*(?:[-*•]|\d+[.)])\s+(.{6,140})\z/, 1]&.strip }
            .reject { |s| existing.include?(s.downcase) }.uniq.first(8)
    end

    # Open tickets touching the same files or sharing many keywords.
    def dependencies(ticket, builder, files)
      mine = builder.ticket_keywords.to_set
      file_set = files.map(&:first).to_set
      candidates = ticket.project.tickets.open.where.not(id: [ ticket.id ] + ticket.depends_on.pluck(:id) + ticket.dependents.pluck(:id)).limit(200)
      candidates.filter_map do |other|
        ob = ContextBuilder.new(ticket: other, repository: ticket.project.repository, max_tokens: 1_000, chdir: nil, action: "advise", handoff: nil)
        overlap = (ob.ticket_keywords.to_set & mine).size
        shared = (ob.relevant_files(limit: 8).map(&:first).to_set & file_set).size
        next unless shared.positive? || overlap >= 4

        [ other, shared.positive? ? "touches #{shared} of the same files" : "#{overlap} shared keywords" ]
      end.first(3)
    end
  end
end
