module Agentboard
  class SettingsController < ApplicationController
    def show
      @config = Agentboard.config
      @doctor = Doctor.new(root: Agentboard.config.root_path).checks
      @outbox = Outbox.stats
    end
  end
end
