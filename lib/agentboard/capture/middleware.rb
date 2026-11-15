module Agentboard
  module Capture
    # Injects the capture widget into the host app's HTML pages (never into AgentBoard's own
    # dashboard) and records which templates rendered the page.
    class Middleware
      MAX_BODY = 5 * 1024 * 1024

      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless Capture.enabled_for_env?
        return @app.call(env) if env["PATH_INFO"].to_s.start_with?(Capture.mount_path + "/") || env["PATH_INFO"] == Capture.mount_path

        Thread.current[:agentboard_capture_collector] = Collector.new
        status, headers, body = @app.call(env)
        inject(env, status, headers, body)
      ensure
        Thread.current[:agentboard_capture_collector] = nil
      end

      private

      def inject(env, status, headers, body)
        type = headers["content-type"] || headers["Content-Type"]
        return [ status, headers, body ] unless status == 200 && type.to_s.include?("text/html")
        return [ status, headers, body ] if env["HTTP_TURBO_FRAME"] || headers["content-disposition"].to_s.include?("attachment")

        html = +""
        body.each { |part| html << part }
        body.close if body.respond_to?(:close)
        index = html.bytesize <= MAX_BODY ? html.rindex("</body>") : nil
        return [ status, headers, [ html ] ] unless index

        html.insert(index, tag(env))
        headers.delete("content-length")
        headers.delete("Content-Length")
        [ status, headers, [ html ] ]
      end

      def tag(env)
        params = env["action_dispatch.request.path_parameters"] || {}
        data = {
          endpoint: "#{Capture.mount_path}/captures", dashboard: Capture.mount_path,
          route: [ params[:controller], params[:action] ].compact.join("#").presence,
          templates: Capture.collector&.templates || [], screenshots: Capture.screenshots?, version: Agentboard::VERSION
        }
        src = "#{Capture.mount_path}/assets/capture.js?v=#{AssetsController.fingerprint("capture.js")}"
        %(<script src="#{src}" data-agentboard-capture="#{ERB::Util.html_escape(JSON.generate(data))}" defer></script>)
      end
    end
  end
end
