module Agentboard
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    before_validation :assign_uuid, on: :create

    private

    def assign_uuid
      self.id ||= Agentboard::Ids.uuid if has_attribute?(:id)
    end
  end
end
