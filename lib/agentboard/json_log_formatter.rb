require "logger"

module Agentboard
  # Structured log records (spec §32.1): timestamp, level, component, correlation and
  # execution ids, event name. Messages are redacted; payloads are never logged.
  class JsonLogFormatter < ::Logger::Formatter
    def initialize(component: "runtime")
      super()
      @component = component
    end

    def call(severity, time, _progname, msg)
      record = { ts: time.utc.iso8601(3), level: severity.downcase, component: @component, pid: ::Process.pid }
      if defined?(Agentboard::Current)
        record[:correlation_id] = Agentboard::Current.correlation_id if Agentboard::Current.correlation_id
      end
      record[:thread] = Thread.current.name if Thread.current.name
      text = msg.is_a?(Exception) ? "#{msg.class}: #{msg.message}" : msg.to_s
      if (m = text.match(/\A\[agentboard(?:\.(\w+))?\]\s*/))
        record[:component] = m[1] if m[1]
        text = m.post_match
      end
      record[:execution_id] = text[/\b([0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12})\b/, 1] if text.include?("execution")
      record[:message] = Redactor.redact(text)[0, 4000]
      JSON.generate(record.compact) + "\n"
    end
  end
end
