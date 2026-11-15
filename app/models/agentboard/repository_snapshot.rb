module Agentboard
  class RepositorySnapshot < ApplicationRecord
    belongs_to :project
  end
end
