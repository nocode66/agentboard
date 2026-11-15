module Agentboard
  class Engine < ::Rails::Engine
    isolate_namespace Agentboard

    ActiveSupport::Inflector.inflections(:en) { |i| i.irregular "criterion", "criteria" }

    # Load YAML configuration before the host's initializers so Ruby config can override it.
    initializer "agentboard.configuration", before: :load_config_initializers do |app|
      Agentboard.config.root ||= app.root
      Agentboard.config.load!
    end

    # Capture widget: middleware + template instrumentation. Annotated view filenames let the
    # widget map a clicked element to the exact template/partial that rendered it.
    initializer "agentboard.capture" do |app|
      app.middleware.use Agentboard::Capture::Middleware
      Agentboard::Capture.subscribe!
      if Rails.env.development? && app.config.action_view.annotate_rendered_view_with_filenames.nil?
        app.config.action_view.annotate_rendered_view_with_filenames = true
      end
    end

    initializer "agentboard.filter_parameters" do |app|
      app.config.filter_parameters |= %i[lease_token token]
    end
  end
end
