module Agentboard
  # Honest metrics (spec §13, §32.2): unknown cost is "—", never zero; provider-reported cost
  # is labeled as such and kept separate from subscription usage.
  class AnalyticsController < ApplicationController
    def show
      executions = Execution.joins(:ticket).where(agentboard_tickets: { project_id: current_project.id }).where.not(provider_key: "local")
      @total = executions.count
      @by_status = executions.group(:status).count
      finished = executions.where.not(finished_at: nil).where.not(started_at: nil).pluck(:started_at, :finished_at)
      @median_duration = median(finished.map { |s, f| f - s })
      @retries = executions.where("attempt > 1").count
      impl = executions.where(action: "implement").where.not(finished_at: nil)
      first_attempts = impl.where(attempt: 1)
      @first_pass_rate = first_attempts.any? ? (first_attempts.where(status: "completed").count * 100.0 / first_attempts.count).round : nil
      @by_provider = executions.group(:provider_key, :status).count.each_with_object(Hash.new { |h, k| h[k] = Hash.new(0) }) { |((p, s), c), h| h[p][s] += c }
      usage = UsageRecord.where(execution_id: executions.select(:id))
      @tokens = usage.group(:provider_key).pluck(:provider_key, Arel.sql("SUM(input_tokens)"), Arel.sql("SUM(output_tokens)"), Arel.sql("COUNT(*)"))
      @reported_cost = usage.where.not(reported_cost: nil).group(:provider_key, :currency).sum(:reported_cost)
      @human_interventions = Event.where(project_id: current_project.id, actor_type: "human")
                                  .where(event_type: %w[approval.approved approval.rejected agent.execution.cancel_requested ticket.transitioned]).count
      @approval_latency = median(Approval.where(project_id: current_project.id).where.not(decided_at: nil).pluck(:created_at, :decided_at).map { |c, d| d - c })
      @verification = VerificationResult.where(execution_id: executions.select(:id)).group(:status).count
      @throughput = current_project.tickets.where.not(completed_at: nil).where("completed_at > ?", 28.days.ago).group_by { |t| t.completed_at.to_date.beginning_of_week }.transform_values(&:size)
      @metrics = (Agentboard.feature?(:governance) && defined?(Agentboard::Pro::Metrics)) ? Agentboard::Pro::Metrics.snapshot(current_project) : nil
      @daily = executions.where("agentboard_executions.created_at > ?", 14.days.ago).group_by { |e| e.created_at.to_date }.transform_values(&:size)
    end

    private

    def median(values)
      return nil if values.empty?

      s = values.sort
      s.size.odd? ? s[s.size / 2] : (s[s.size / 2 - 1] + s[s.size / 2]) / 2.0
    end
  end
end
