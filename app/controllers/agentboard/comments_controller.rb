module Agentboard
  class CommentsController < ApplicationController
    def create
      ticket = find_ticket
      Tickets.add_comment!(ticket: ticket, actor: current_actor, body: params.require(:comment).require(:body))
      redirect_to ticket_path(ticket, anchor: "activity"), status: :see_other
    end
  end
end
