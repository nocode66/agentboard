module Agentboard
  class CapturesController < ApplicationController
    def create
      return head(:not_found) unless Capture.enabled_for_env?

      ticket = Captures.create!(project: current_project, actor: current_actor, params: params.require(:capture).to_unsafe_h)
      render json: { ok: true, key: ticket.key, url: ticket_url(ticket) }, status: :created
    end

    def screenshot
      artifact = Artifact.joins(:ticket).where(agentboard_tickets: { project_id: current_project.id }, kind: "screenshot").find(params[:id])
      path = artifact.uri.delete_prefix("file:")
      PathGuard.within!(Agentboard.config.root_path.join(".agentboard", "captures"), path)
      send_file path, type: "image/png", disposition: "inline"
    end
  end
end
