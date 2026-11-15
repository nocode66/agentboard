module Agentboard
  # Dashboard authentication (spec §14, open decision #1 — recommended default):
  #   1. host-auth adapter: `config.authenticate_with = ->(controller) { actor_or_nil }`
  #   2. otherwise local-only access with an optional dashboard token
  # The engine refuses to serve in production unless explicitly enabled.
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception
    layout "agentboard/application"

    before_action :refuse_production!
    before_action :authenticate_agentboard!
    around_action :with_correlation

    helper_method :current_actor, :current_project, :pending_approvals_count, :can?, :edition_notices

    rescue_from Agentboard::Error, with: :render_domain_error
    rescue_from ActiveRecord::StaleObjectError do
      render_domain_error(Agentboard::Error.version_conflict("Someone else changed this record; reload and try again"))
    end
    rescue_from ActiveRecord::RecordInvalid do |e|
      render_domain_error(Agentboard::Error.validation_failed(e.record.errors.full_messages.to_sentence))
    end

    private

    def current_actor = @current_actor
    def can?(permission) = Authorization.allowed?(current_actor, permission)
    def edition_notices = @edition_notices ||= Extensions.run(:dashboard_notices).flatten.compact.uniq
    def current_project = @current_project ||= Project.current

    def pending_approvals_count
      @pending_approvals_count ||= Approval.pending.where(project_id: current_project.id).count
    end

    def refuse_production!
      return unless Rails.env.production? && !Agentboard.config.mount_in_production

      head :not_found
    end

    # Host-app authentication with roles is team mode (AgentBoard Pro). Without a licence
    # the dashboard falls back to local single-user access instead of failing open.
    def authenticate_agentboard!
      hook = Agentboard.config.authenticate_with
      if hook && Agentboard.feature?(:team_mode)
        @current_actor = hook.call(self)
        return head(:unauthorized) unless @current_actor
      else
        unless request.local? || Agentboard.config.allow_non_local_requests
          return render plain: "AgentBoard only accepts local requests by default.", status: :forbidden
        end
        if (token = Agentboard.config.dashboard_token).present?
          if params[:token].present? && ActiveSupport::SecurityUtils.secure_compare(params[:token].to_s, token)
            session[:agentboard_authenticated] = true
          end
          return render(plain: "Dashboard token required (?token=…)", status: :unauthorized) unless session[:agentboard_authenticated]
        end
        @current_actor = Authorization.local_human
      end
      Current.actor = @current_actor
    end

    def with_correlation
      Current.correlation_id = request.request_id.presence || Ids.correlation
      yield
    end

    def render_domain_error(error)
      respond_to do |format|
        format.json { render json: Result.failure(error, correlation_id: Current.correlation_id).to_h, status: http_status(error) }
        format.html do
          flash[:alert] = error.message
          redirect_back fallback_location: root_path, status: :see_other
        end
      end
    end

    def http_status(error)
      {
        "NOT_FOUND" => :not_found, "UNAUTHORIZED" => :unauthorized, "FORBIDDEN" => :forbidden, "VALIDATION_FAILED" => :unprocessable_entity,
        "VERSION_CONFLICT" => :conflict, "LEASE_CONFLICT" => :conflict, "LEASE_EXPIRED" => :conflict, "INVALID_TRANSITION" => :unprocessable_entity,
        "POLICY_DENIED" => :forbidden, "APPROVAL_REQUIRED" => :forbidden, "RATE_LIMITED" => :too_many_requests
      }.fetch(error.code, :unprocessable_entity)
    end

    def find_ticket(key = params[:ticket_key] || params[:key])
      Ticket.find_by_key!(key, project: current_project)
    end
  end
end
