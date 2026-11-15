module Agentboard
  module Providers
    # Provider adapter contract. Passive (MCP/hooks/event ingestion) and active
    # (launch/stream/cancel/resume) are separate concerns so partial support is explicit.
    # Unsupported features raise UnsupportedCapability (CAPABILITY_UNAVAILABLE).
    class Base
      class << self
        def key = raise(NotImplementedError)
        def display_name = key.to_s.capitalize
        def binary = nil

        # Compatibility manifest: lib/agentboard/providers/compatibility/<key>.yml
        def compatibility
          @compatibility ||= begin
            path = File.expand_path("compatibility/#{key}.yml", __dir__)
            File.exist?(path) ? YAML.safe_load(File.read(path), aliases: false) : { "provider" => key.to_s, "validated" => [] }
          end
        end
      end

      attr_reader :settings

      def initialize(settings: nil)
        @settings = settings || Agentboard.config.provider_settings(self.class.key)
      end

      def key = self.class.key.to_s
      def display_name = self.class.display_name

      # -- discovery -----------------------------------------------------------------
      def probe(environment: ENV) = raise(NotImplementedError)
      def capabilities(environment: ENV) = probe(environment: environment).supported_capabilities
      def detect = probe.installed
      def supports?(cap) = Array(capabilities).include?(cap.to_sym)

      # -- passive -------------------------------------------------------------------
      def install_passive_hooks(project:, root:) = raise(UnsupportedCapability.new(:passive_hooks, provider: key))
      def remove_passive_hooks(project:, root:, manifest:) = raise(UnsupportedCapability.new(:passive_hooks, provider: key))
      def configure_passive(context:) = install_passive_hooks(project: context[:project], root: context[:root])

      # Maps a raw hook payload to [NormalizedEvent] (hook ingestion).
      def parse_hook(event_name:, payload:) = raise(UnsupportedCapability.new(:passive_hooks, provider: key))

      # -- active --------------------------------------------------------------------
      def launch_spec(execution:, worktree:, context_path:, prompt:) = raise(UnsupportedCapability.new(:active_execution, provider: key))

      # Parses one line of provider stdout into zero or more NormalizedEvents.
      def parse_event(raw_event:) = raise(UnsupportedCapability.new(:structured_events, provider: key))

      def resume_spec(execution:, worktree:, input:) = raise(UnsupportedCapability.new(:session_resume, provider: key))

      # Cancellation is performed by the supervisor via the process group; providers that
      # need protocol-level interruption override this.
      def interrupt(handle:)
        raise UnsupportedCapability.new(:cancellation, provider: key) unless supports?(:cancellation)

        Subprocess.terminate(handle.fetch(:pgid), grace: Agentboard.config.runtime["cancel_grace_seconds"].to_i)
      end

      # Back-compat names from spec §5.
      def start(execution:) = raise(UnsupportedCapability.new(:active_execution, provider: key))
      def events(session:, cursor: nil) = raise(UnsupportedCapability.new(:structured_events, provider: key))
      def cancel(session:) = raise(UnsupportedCapability.new(:cancellation, provider: key))
      def resume(handle:, input: nil) = raise(UnsupportedCapability.new(:session_resume, provider: key))

      protected

      def run_version(argv)
        out, _err, status = Open3.capture3(Subprocess.scrubbed_env, *argv)
        status.success? ? out.strip : nil
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      def which(bin)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          path = File.join(dir, bin)
          return path if File.file?(path) && File.executable?(path)
        end
        nil
      end

      # Conservative capability negotiation (AT-14): capabilities listed for a validated
      # version are enabled; unknown versions only get passive, low-risk capabilities unless
      # the operator explicitly opts in with `allow_unvalidated_versions: true`.
      def negotiate(version, all_caps, safe_caps: %i[mcp])
        entry = Array(self.class.compatibility["validated"]).find { |v| version.to_s.include?(v["binary_version"].to_s) }
        if entry
          caps = Array(entry["capabilities"]).map(&:to_sym) & all_caps
          [ caps, entry["status"] || "validated", [ entry["smoke_test"] ].compact ]
        elsif settings["allow_unvalidated_versions"]
          [ all_caps, "unvalidated (operator opt-in)", [ "#{display_name} #{version} is not in the compatibility manifest; running with operator opt-in." ] ]
        else
          [ safe_caps & all_caps, "unknown version",
            [ "#{display_name} #{version || "(unknown)"} is not in the compatibility manifest. Active execution is disabled; " \
              "set providers.#{key}.allow_unvalidated_versions: true to opt in after testing." ] ]
        end
      end

      def safe_json(line)
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
