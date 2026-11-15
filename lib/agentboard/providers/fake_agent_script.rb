# Deterministic fake coding agent used by AgentBoard's Fake provider.
# Reads the prompt from stdin, emits JSONL on stdout and edits the current directory.
require "json"
require "fileutils"

$stdout.sync = true
args = ARGV.each_slice(2).to_h
scenario = args.fetch("--scenario", "success")
prompt = $stdin.read.to_s
ticket = ENV.fetch("AGENTBOARD_TICKET", "UNKNOWN")

emit = ->(h) { puts(JSON.generate(h)) }
trap("TERM") { emit.call(type: "message", text: "received SIGTERM, stopping"); exit 143 }

emit.call(type: "session", session_id: args["--session"] || "fake-#{Process.pid}", model: "fake-1")
emit.call(type: "message", text: "Read #{prompt.bytesize} bytes of context for #{ticket}.")

case scenario
when "malformed"
  puts "this is not json {"
  emit.call(type: "mystery", foo: 1)
when "secret"
  emit.call(type: "message", text: "Found key sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 in env")
when "permission"
  emit.call(type: "permission", tool: "Bash", reason: "wants to run rm -rf tmp/")
when "env"
  # Simulates an agent that obeys a prompt-injected instruction to dump its environment.
  ENV.sort.each { |k, v| emit.call(type: "message", text: "#{k}=#{v}") }
when "resume"
  emit.call(type: "message", text: "Resumed session #{args["--session"]}: #{prompt.strip[0, 80]}")
when "slow"
  20.times { |i| emit.call(type: "message", text: "working… #{i}"); sleep 0.5 }
end

unless scenario == "noop"
  emit.call(type: "tool_start", tool: "Edit", target: "AGENTBOARD_NOTES.md")
  File.open("AGENTBOARD_NOTES.md", "a") { |f| f.puts("- #{ticket}: change by fake agent (#{scenario})") }
  emit.call(type: "tool_end", tool: "Edit", target: "AGENTBOARD_NOTES.md", ok: true)
end
emit.call(type: "usage", input_tokens: prompt.bytesize / 4, output_tokens: 42)

if scenario == "fail"
  emit.call(type: "result", ok: false, summary: "Could not complete the task")
  exit 1
end
emit.call(type: "result", ok: true, summary: "Implemented #{ticket} (fake)")
exit 0
