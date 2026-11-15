module Agentboard
  # In-app capture widget: select elements on any screen of the host app and turn them into
  # an AgentBoard ticket with the page, route, view templates, DOM context and console errors.
  #
  # Editions: Community — development environment, local user. Pro (`capture`) — other
  # environments (e.g. staging, with team-mode authentication) and region screenshots.
  module Capture
    module_function

    def settings
      { "enabled" => true, "environments" => %w[development], "annotate_views" => true }.merge(Agentboard.config.settings["capture"].to_h)
    end

    def enabled_for_env?(env = Rails.env)
      return false unless settings["enabled"]
      return true if env.to_s == "development" && Array(settings["environments"]).include?("development")

      Array(settings["environments"]).map(&:to_s).include?(env.to_s) && Agentboard.feature?(:capture)
    end

    def screenshots? = Agentboard.feature?(:capture)

    def mount_path
      @mount_path ||= begin
        route = Rails.application.routes.routes.find { |r| r.app.respond_to?(:app) && r.app.app == Agentboard::Engine }
        route ? route.path.spec.to_s.sub(/\(\.:format\)\z/, "").chomp("/") : "/agentboard"
      end
    end

    def reset! = @mount_path = nil

    # Collects the templates and partials rendered while handling one request.
    class Collector
      attr_reader :templates

      def initialize = @templates = []

      def add(identifier)
        root = Rails.root.to_s + "/"
        path = identifier.to_s.start_with?(root) ? identifier.to_s.delete_prefix(root) : nil
        @templates << path if path && !@templates.include?(path) && @templates.size < 200
      end
    end

    def collector = Thread.current[:agentboard_capture_collector]

    def subscribe!
      return if @subscribed

      %w[render_template.action_view render_partial.action_view render_collection.action_view].each do |name|
        ActiveSupport::Notifications.subscribe(name) { |*, payload| collector&.add(payload[:identifier]) }
      end
      @subscribed = true
    end
  end
end
require "agentboard/capture/middleware"
