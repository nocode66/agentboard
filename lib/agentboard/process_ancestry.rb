module Agentboard
  # Finds the agent process (claude, codex, cursor-agent…) that spawned the current process.
  # MCP servers and hook commands are both children of the same agent process, which lets
  # AgentBoard correlate an MCP session with the provider's hook-reported session without
  # trusting any identifier supplied by the agent. Works on macOS and Linux (`ps`).
  module ProcessAncestry
    AGENT_COMMANDS = /\A(claude|codex|cursor-agent|cursor|gemini|opencode|copilot)\z/i
    MAX_DEPTH = 12

    Agent = Struct.new(:pid, :command, :fingerprint, keyword_init: true) do
      def to_h = { "agent_pid" => pid, "agent_command" => command, "agent_fingerprint" => fingerprint }
    end

    module_function

    def find_agent(start_pid = ::Process.ppid)
      pid = start_pid
      MAX_DEPTH.times do
        break if pid.nil? || pid <= 1

        ppid, comm = info(pid)
        name = File.basename(comm.to_s)
        return Agent.new(pid: pid, command: name, fingerprint: Subprocess.fingerprint(pid)) if name.match?(AGENT_COMMANDS)

        pid = ppid
      end
      nil
    end

    def info(pid)
      out, _e, st = Open3.capture3("ps", "-o", "ppid=,comm=", "-p", pid.to_s)
      return [ nil, nil ] unless st.success?

      ppid, comm = out.strip.split(/\s+/, 2)
      [ ppid.to_i, comm ]
    rescue StandardError
      [ nil, nil ]
    end
  end
end
