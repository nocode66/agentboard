module Agentboard
  class Current < ActiveSupport::CurrentAttributes
    attribute :correlation_id, :actor
  end
end
