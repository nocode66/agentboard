module Agentboard
  class BoardController < ApplicationController
    def show
      @filters = params.permit(:q, :kind, :priority, :label, :agent, :milestone).to_h.compact_blank
      scope = current_project.tickets.where(status: StateMachines::Ticket::BOARD_COLUMNS + %w[blocked reopened])
                             .includes(:project, :acceptance_criteria, :leases, :executions, :depends_on)
      scope = apply_filters(scope)
      tickets = scope.ordered.to_a
      done_cutoff = Agentboard.config.settings.dig("board", "done_visible_days").to_i.days.ago
      @columns = Agentboard.config.board_columns.index_with { [] }
      tickets.each do |t|
        col = if t.status == "blocked" && t.leases.any? { |l| l.released_at.nil? }
          Agentboard.config.board_column_for("in_progress")
        else
          Agentboard.config.board_column_for(t.status)
        end
        next if t.status == "done" && t.completed_at && t.completed_at < done_cutoff

        @columns[col] << t
      end
      @labels = current_project.tickets.pluck(:labels).flatten.uniq.sort
      @milestones = current_project.milestones.where(status: "open").order(:target_date, :name)
      @active_executions = Execution.active.joins(:ticket).where(agentboard_tickets: { project_id: current_project.id }).includes(:ticket).limit(6)
    end

    private

    def apply_filters(scope)
      if (q = @filters["q"]).present?
        if (m = q.strip.upcase.match(/\A#{Regexp.escape(current_project.key)}-(\d+)\z/))
          scope = scope.where(number: m[1].to_i)
        else
          scope = scope.where("LOWER(title) LIKE :q OR LOWER(description) LIKE :q", q: "%#{ActiveRecord::Base.sanitize_sql_like(q.downcase)}%")
        end
      end
      scope = scope.where(kind: @filters["kind"]) if @filters["kind"].present?
      scope = scope.where(milestone_id: @filters["milestone"]) if @filters["milestone"].present?
      scope = scope.where(priority: @filters["priority"].to_i) if @filters["priority"].present?
      if @filters["label"].present?
        ids = scope.select { |t| t.labels.include?(@filters["label"]) }.map(&:id)
        scope = scope.where(id: ids)
      end
      scope
    end
  end
end
