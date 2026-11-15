# Changelog

## Unreleased

- **Open core (decision 35.2 #6):** a new `agentboard-pro` gem (`pro/`) holds team mode,
  advanced workflows, governance and the GitHub integration. Ed25519 licences are verified
  offline. Expiry gives 14 days of grace, then Pro features stop; data is never affected.
- **Team mode (#1):** host-app authentication adapter (`rails g agentboard:pro:team`),
  role-aware UI, separation of duties on approvals.
- **Database (#2):** team mode requires PostgreSQL. The daemon refuses to start on SQLite,
  and `doctor` reports it.
- **Distribution:** `agentboard` publishes to RubyGems.org through Trusted Publishing. The
  site serves `agentboard-pro` from a private Bundler compact-index server, authenticated
  by the customer's licence; access follows the subscription. Verified with real Bundler.
- **Capture widget:**
  - Select elements on any page of the host app and create a ticket. The ticket records
    the route, the exact templates and partials (from view annotations), a selector, a
    redacted HTML fragment and console errors.
  - Captured templates are placed first in the agent's context.
  - Community covers development; Pro (`capture`) adds other environments and region
    screenshots.
- **Agents in containers (core):**
  - `sandbox.agents: true` runs Claude, Codex and the fake provider in OCI containers on an
    internal network. The only exit is an allowlisting egress proxy.
  - Credentials are forwarded by name. Containers are removed on cancel and on runtime
    reconciliation.
  - New commands `agentboard sandbox init/build/status/down` and a Dockerfile template.
  - Verification containers now mount paths identically, so Git resolves inside them.
- **Git hosting:** GitLab and Bitbucket alongside GitHub, behind one adapter contract
  (webhook authentication, PR/MR normalisation, repository identity, PR creation). The
  licence feature is now `git_hosting`; `github` stays accepted as an alias.
- **Completion (#5):** `require_merged_pr: when_linked` is the default.
- **Core:** extension registry and hooks (`Agentboard::Extensions`), `session.manage`
  permission, edition shown in `doctor` and the dashboard.

## 0.2.0

- **F21 GitHub:** signed webhooks, PR association by repository, branch and SHA, and
  merge-aware completion (AT-11). Manual PR links are verified against local Git history.
- **F18 permission bridge:** Claude Code permission prompts become human approvals bound
  to the execution. CommandPolicy denies production, protected-branch and credential
  operations.
- **F14:** provider session resume in the same worktree; process-group CPU and memory
  accounting.
- **F19:** per-step workflow timeouts and signed `external` integration steps.
- **F07/F08/F11:** rotating, revocable MCP session credentials; MCP and hook sessions
  correlated through process ancestry; opt-in Codex `notify`.
- **F22:** ticket drafting suggestions that require human acceptance; static route and
  table introspection; repository snapshots.
- **F23:** JSON daemon logs, operational metrics, `support-bundle`, `retention`, `purge`.
- **F06:** milestones, subtasks, configurable board columns.
- **F15/F16:** real-provider fixtures. Claude Code 2.1.325 smoke-tested end to end.
- **AT-15:** upgrade path with versioned event payloads and upcasters. PostgreSQL in CI.
- Fixes:
  - Live dashboard refresh (Turbo ESM import).
  - Context builder crash on empty files.
  - Hook stdin read before boot.
  - `--json` in subcommands.

## 0.1.0

- First implementation: engine, domain core, MCP, runtime daemon, workflows, dashboard.
