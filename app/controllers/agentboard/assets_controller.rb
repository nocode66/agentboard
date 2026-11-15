module Agentboard
  # Serves the engine's precompiled CSS/JS and the Turbo/Stimulus builds shipped inside their
  # gems, so the dashboard works with any (or no) host asset pipeline and without Node.
  class AssetsController < ActionController::Base
    skip_forgery_protection

    def self.asset_paths
      @asset_paths ||= {
        "agentboard.css" => Agentboard::Engine.root.join("app/assets/stylesheets/agentboard/application.css"),
        "agentboard.js" => Agentboard::Engine.root.join("app/javascript/agentboard/application.js"),
        "capture.js" => Agentboard::Engine.root.join("app/javascript/agentboard/capture.js"),
        "turbo.js" => Pathname.new(Gem.loaded_specs.fetch("turbo-rails").full_gem_path).join("app/assets/javascripts/turbo.min.js"),
        "stimulus.js" => Pathname.new(Gem.loaded_specs.fetch("stimulus-rails").full_gem_path).join("app/assets/javascripts/stimulus.min.js")
      }
    end

    def self.fingerprint(name)
      @fingerprints ||= {}
      @fingerprints[name] = nil if Rails.env.development?
      @fingerprints[name] ||= Digest::SHA256.file(asset_paths.fetch(name)).hexdigest[0, 12]
    end

    def show
      path = self.class.asset_paths[params[:name]] or return head(:not_found)
      type = params[:name].end_with?(".css") ? "text/css" : "text/javascript"
      if params[:v].present? && !Rails.env.development?
        expires_in 1.year, public: true
      end
      send_file path, type: "#{type}; charset=utf-8", disposition: "inline"
    end
  end
end
