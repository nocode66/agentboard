# AgentBoard

A local-first ticket board and agent orchestration engine for Rails apps. It connects
tickets to Claude Code, OpenAI Codex, Cursor and third-party adapters. Ticket completion is
based on evidence (commits, checks bound to a commit SHA, human approval), not on what an
agent says about its own work.

```
requirements → tickets → agent sessions → executions → code changes → tests → reviews → delivery
```

The full specification is in `AgentBoard_Engineering_Spec_v1.1.md`, and the change history
in `CHANGELOG.md`.

- [Editions](#editions)
- [Quick start](#quick-start-macos--linux)
- [How it works](#how-it-works)
- [Running agents safely](#running-agents-safely)
- [Configuration](#configuration)
- [CLI](#cli)
- [Pro features](#pro-features)
- [Development](#development)
- [Status and known limits](#status-and-known-limits)

## Editions

| | Community (`agentboard`, MIT) | Pro (`agentboard-pro`, commercial licence) |
|---|---|---|
| Tickets, Kanban, backlog, milestones, subtasks | ✓ | ✓ |
| MCP server for agents, passive tracking through provider hooks | ✓ | ✓ |
| Active execution: worktrees, live console, cancel/retry/resume, verification | ✓ | ✓ |
| Agent isolation: trusted local processes or containers with an egress allowlist | ✓ | ✓ |
| Human approvals, permission bridge for agent tool use | ✓ | ✓ |
| Sequential workflows (agent, command and approval steps) | ✓ | ✓ |
| Manual PR links verified against Git | ✓ | ✓ |
| Basic analytics, export, manual retention and purge | ✓ | ✓ |
| Capture widget: select elements in your app and file a ticket (development) | ✓ | ✓ |
| Capture widget on staging for the whole team, plus region screenshots | — | ✓ |
| Team mode: host-app login, roles, separation of duties (PostgreSQL) | — | ✓ |
| Advanced workflows: conditions, retries, timeouts, external and PR steps | — | ✓ |
| Governance: ops metrics, support bundle, hash-chained audit export, daily retention | — | ✓ |
| Git hosting: GitHub, GitLab and Bitbucket webhooks, merge-aware completion, PR/MR creation | — | ✓ |

- The core never needs an account or network access.
- A Pro licence is verified offline.
- When a Pro licence lapses, you get 14 days of grace, then Pro features stop. Data and
  Community features are never affected.

## Quick start (macOS / Linux)

```bash
bundle add agentboard --group development
bin/rails generate agentboard:install            # idempotent; never overwrites without --force
bin/rails db:migrate
bundle exec agentboard init                      # .agentboard/, .gitignore entries, provider detection
bundle exec agentboard doctor                    # checks everything and tells you what is missing
bundle exec agentboard provider setup claude     # MCP (.mcp.json) + hooks (.claude/settings.local.json)
bundle exec agentboard provider setup codex      # MCP via `codex mcp add` (add --notify for turn events)
bundle exec agentboard daemon start              # agents run in this process, not in the web server
open http://localhost:3000/agentboard
```

**Requirements:**
- Ruby 3.3 or newer, Rails 7.2 or 8.x, Git.
- PostgreSQL is recommended. SQLite works for a single developer.
- The core needs neither Node nor Python. The CSS is precompiled, and Turbo and Stimulus
  are served from their gems.

**Try it without a real agent:** create a ticket on the board, open it, then
**Run an agent → Fake agent**. The built-in fake provider edits a file, commits, runs your
tests and hands the ticket to review. It calls no paid API.

## How it works

```
Rails host app ── AgentBoard engine: dashboard, domain services, event store + outbox
                    │  MCP stdio server   (agentboard mcp serve)      ← agents read/update tickets
                    │  hook ingestion     (agentboard hook ingest)    ← provider lifecycle events
                    ▼
            Runtime daemon (separate OS process, authenticated Unix-socket IPC)
              supervisor · worktrees · context builder · verification · DAG workflows
              providers: fake · claude · codex · cursor (MCP) · gemini/opencode/copilot (detection)
              isolation: trusted local process | container + egress proxy
```

**Two ways to work with agents:**

1. **Passive.** You run `claude` or `codex` yourself. Through MCP the agent can list,
   claim, update and submit tickets. Hooks report what it does, and Git provides the
   evidence. Every event is labelled with its provenance (confirmed by AgentBoard, reported
   by the provider, observed in Git, or inferred).
2. **Active.** AgentBoard launches the agent in a dedicated worktree. It gives the agent a
   bounded context (ticket, criteria, relevant files, routes and tables read statically
   with Prism), streams its output and commits the result. It then runs the approved test
   commands against that exact commit and requests a human review.

**A ticket reaches Done only when all of these hold:**
- acceptance criteria are verified by a human;
- the required checks passed on the reviewed commit;
- a human approved the review;
- if a PR is linked, that PR was merged on the reviewed commit.

Agents can request completion but cannot bypass any of these.

## Running agents safely

Real agents never start by default. Choose one mode in `.agentboard/config.yml`:

| Mode | Config | What the agent can reach |
|---|---|---|
| Off (default) | — | Only the fake provider runs |
| Trusted local process | `security.trusted_local_execution: true` | Your user account. Shell commands need human approval, through the permission bridge for Claude. |
| Container | `security.sandbox: container` + `sandbox.agents: true` | Only its worktree and the git directory; network only to provider APIs |

Setting up container mode:

```bash
bundle exec agentboard sandbox init      # writes .agentboard/sandbox/Dockerfile (Ruby + your gems + agent CLIs)
bundle exec agentboard sandbox build     # builds the image and prints the config to enable
bundle exec agentboard sandbox status    # runtime, network, egress allowlist
```

**What container isolation enforces:**
- **Network:** an internal Docker network with no route to the internet. The only exit is
  an egress proxy that allowlists provider APIs; everything else is refused and logged.
- **Filesystem:** read-only root filesystem, all capabilities dropped, no-new-privileges,
  non-root user. Only the worktree and the repository's git directory are mounted.
- **Credentials:** forwarded by variable name, so values never appear in process listings.
- **Permissions:** inside the container the agent may use tools without prompts. On the
  host it never can.
- **Cleanup:** containers are removed on cancel and when the daemon restarts.

**Always on, in every mode:**
- Commands come only from an approved catalog and run as argv. Nothing goes through a
  shell, and ticket text never reaches argv.
- Secrets are redacted from logs, events, comments and exports.
- Model reasoning is never stored.
- Production deploys, protected-branch pushes and credential reads are denied by policy
  before any human is asked.
- Approvals are bound to the exact action and commit. A code change invalidates them.

Details are in `docs/THREAT_MODEL.md`.

## Capture widget

In development, every HTML page of your app gets a small **AgentBoard** button
(<kbd>Alt</kbd>+<kbd>Shift</kbd>+<kbd>A</kbd>). Click it, select one or more elements
(<kbd>Shift</kbd>+click to add), describe the problem and create a ticket. The ticket
records:

- the page and its `controller#action`;
- **the exact template or partial that rendered each element** (from Rails'
  `annotate_rendered_view_with_filenames`, which AgentBoard turns on in development);
- a stable selector and a redacted HTML fragment (input values are never captured);
- console errors.

When an agent works on that ticket, those templates come first in its context. The
widget runs in a closed Shadow DOM, so it neither affects nor is affected by your CSS.

With Pro (`capture`), the widget can be enabled for other environments, typically staging
for QA and PMs with team-mode login, and can attach a screenshot cropped to the selection
using the browser's native screen-capture API:

```yaml
capture:
  environments: [development, staging]
```

## Configuration

`bin/rails generate agentboard:install` writes `config/agentboard.yml`. Local overrides go
in `.agentboard/config.yml`. The most important keys:

```yaml
security:
  trusted_local_execution: false   # opt-in for real agents as local processes
  sandbox: none                    # container: verification (and agents, see below) in Docker
sandbox:
  agents: false                    # true: agents run in containers
  agent_image: agentboard-agent:myapp
  image: agentboard-agent:myapp    # for verification commands (--network none)
  credential_env: [ANTHROPIC_API_KEY, OPENAI_API_KEY]
  egress_allow: []                 # extra host:port beyond provider APIs
completion:
  require_merged_pr: when_linked   # when_linked | always | never
verification_commands:             # the only commands AgentBoard will ever run
  rails_test: { argv: ["bin/rails", "test"], timeout_seconds: 900, required: true }
board:
  columns: [backlog, ready, claimed, in_progress, testing, review, done]
```

Dashboard access defaults to localhost only, as a single local administrator. Team login
with roles is a Pro feature: `rails g agentboard:pro:team`.

## CLI

Run `agentboard help` for the full list. Most commands accept `--json`.

| Area | Commands |
|---|---|
| Setup | `init`, `doctor`, `provider list/setup/remove/doctor`, `sandbox init/build/status/down`, `uninstall` |
| Tickets | `ticket list/show/create/move`, `attach KEY`, `verify KEY`, `approvals`, `approve ID [--reject]` |
| Execution | `run KEY [--provider claude] [--wait]`, `executions`, `logs ID [-f]`, `cancel ID`, `resume ID` |
| Workflows | `workflow validate/list/run` |
| Runtime | `daemon start/stop/status/restart`, `mcp serve`, `hook ingest/replay` |
| Data | `export`, `retention [--dry-run]`, `purge --confirm KEY`, `cleanup [--dry-run]` |
| Pro | `license`, `support-bundle`, `audit-export [--verify FILE]` |

Exit codes:
- 0: ok
- 1: internal error
- 2: validation error or invalid transition
- 3: not found
- 4: forbidden or policy denied
- 5: conflict
- 6: provider or capability unavailable
- 7: daemon not running

## Pro features

`agentboard-pro` is distributed from a private gem server, and your licence is the
credential:

```ruby
source "https://agent-board.live/gems" do
  gem "agentboard-pro", group: :development
end
```

```bash
bundle config set --global agent-board.live "<licence>"
```

At runtime, provide the licence in one of these places: `AGENTBOARD_LICENSE`,
`config/agentboard.license` or `~/.config/agentboard/license`.

- **Team mode.** Run `rails g agentboard:pro:team` to use your app's login (Devise or any
  other) with the roles viewer, developer, maintainer and administrator. The UI respects
  the role, and whoever requests an approval cannot decide it. PostgreSQL is required.
- **Git hosting.** Point a pull/merge-request webhook at `/agentboard/webhooks/github`,
  `/gitlab` or `/bitbucket`, and export the secret named under `git_hosts`. Without a
  secret, the endpoint does not exist. Workflow `git_pull_request` steps open PRs/MRs on
  the detected host.
- **Advanced workflows.** `condition`, `retry`, `timeout_seconds`, `external` (signed
  calls to allowlisted URLs) and `git_pull_request`.
- **Governance.** Queue and lag metrics, `support-bundle`, a tamper-evident
  `audit-export`, and daily retention run by the daemon.

Pricing and licences: https://agent-board.live/pricing

## Development

```bash
bundle install
cd test/dummy && bin/rails db:prepare && RAILS_ENV=test bin/rails db:prepare && cd ../..
bin/rails test                         # SQLite
DB=postgresql PGHOST=/tmp bin/rails test
bin/test-and-commit                    # commits only when both suites are green
cd test/dummy && bin/rails server      # dashboard on http://localhost:3000/agentboard
```

The suite covers units, services, acceptance scenarios AT-01…AT-15, security negatives
(prompt injection, forged webhooks, path traversal, approval replay), real provider
fixtures and container isolation. With Docker running, it also uses a real container.

Upgrading an installation:

```bash
bundle update agentboard
bin/rails agentboard:install:migrations && bin/rails db:migrate
bundle exec agentboard daemon restart
```

Historical events are never rewritten. Old payloads are upcast when read (see
`lib/agentboard/event_schema.rb`).

### macOS notes

- On macOS, Unix socket paths are limited to 104 bytes and `$TMPDIR` is long. The runtime
  socket falls back to `/tmp/agentboard-<uid>/`.
- `/var` and `/tmp` are symlinks into `/private`. Path checks compare real paths.
- Process supervision uses POSIX process groups. Containers run through Docker Desktop.

## Status and known limits

See also `docs/COMPATIBILITY.md` and `docs/RELEASE.md`.

**Verified live (macOS, Docker Desktop):**
- **Claude Code 2.1.325, as a local process:** end-to-end run through AgentBoard
  (implement → snapshot → `bin/rails test` → review). A real permission request went
  through the approval bridge and was correctly denied on expiry.
- **Containers:**
  - The agent image builds from `agentboard sandbox build`.
  - The fake agent runs and commits inside a container.
  - Verification runs `bin/rails test` in a network-less container.
  - Egress, tested from inside the agent network: direct internet is blocked, a
    non-allowlisted domain is refused and logged, a provider API is reachable.
- **Codex in a container:** credentials reach the API through the proxy (`CODEX_API_KEY`
  mapped from `OPENAI_API_KEY`, never in argv). A successful run still needs a valid
  OpenAI key; the one tested was rejected by OpenAI.
- **Claude Code in a container:** needs `ANTHROPIC_API_KEY` or a dedicated
  `sandbox.claude_config_dir` logged in once. A subscription login stored in the macOS
  Keychain is not available inside containers.

**Other limits:**
- The permission bridge (human approval per tool call) exists only for Claude Code running
  as a local process. In a container, the container is the boundary.
- GitLab and Bitbucket integrations are covered by tests on realistic payloads and API
  calls, but have not been run against live repositories.
- Windows is not supported.
- Extra lifecycle transitions were added beyond spec §24.1:
  - `claimed→ready` (release)
  - `testing→in_progress` (failed checks)
  - `review→in_progress` (changes requested)
  - `reopened→ready`
  - `ready→backlog`
