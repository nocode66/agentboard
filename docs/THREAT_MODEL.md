# AgentBoard threat model

Scope: the embedded (local-first) edition. A team or hosted edition needs its own model
(spec §35.1).

## Trust boundaries

| Boundary | Trusted? | Notes |
|---|---|---|
| Human using the dashboard or CLI | Yes, after authentication | By default only local requests are accepted. The host-app auth adapter is optional. |
| AgentBoard app, database, daemon | Yes | Separate OS processes. IPC uses a 0700 directory, a 0600 socket and a bearer token checked on every request. |
| Agent provider process and its output | **No** | Output is evidence with provenance and never authority. |
| Repository content and ticket text | **No** | Fenced as data in context packages and never evaluated. |
| GitHub webhooks | Only with a valid HMAC signature | Deliveries are deduplicated by ID. |
| External integrations | Admin allowlist only | Requests are HMAC-signed and redirects are not followed. |

## Threats and controls

| Threat | Control | Test |
|---|---|---|
| Prompt injection in tickets or repository files | Context fences untrusted text. Policies live in config, not in prompts. Agents cannot change settings or approve. | `security_negative_test.rb` |
| Secret exfiltration by an agent | Allowlisted subprocess environment and redaction of logs, events, comments, exports and the support bundle | `security_negative_test.rb`, AT-13 |
| Agent spoofing another session | Session IDs from agents are labels only. Lease tokens are bound to the session and stored as digests. MCP sessions use rotating, revocable credentials. | `mcp_test.rb`, `session_security_test.rb` |
| Stale worker acting after its lease ended | Leases expire and carry fencing tokens. A partial unique index enforces one live lease per ticket. | AT-04, `tickets_and_leases_test.rb` |
| Shell or command injection | Commands are argv arrays from an approved catalog. Ticket text goes over stdin, never into argv. | `security_negative_test.rb` |
| Path traversal or symlink escape | PathGuard resolves real paths. Worktree names are validated. | `pure_test.rb`, `security_negative_test.rb` |
| Production deploy, protected-branch push, credential read | CommandPolicy denies these before any human prompt, and the denial is audited | `permission_bridge_test.rb` |
| Approval replay after the code changes | Approvals bind to an action digest and a head SHA. A new head invalidates them. They expire. | AT-10, `completion_and_approvals_test.rb` |
| Verification for one commit used for another | Results are bound to the commit SHA. A dirty tree is never bound to a commit. | AT-08 |
| Forged or replayed webhooks | HMAC-SHA256 verification, delivery deduplication, repository identity check | `github_integration_test.rb` |
| Hook replay or flooding | Dedupe keys, bounded payloads, write rate limits on MCP | `providers_test.rb`, `mcp_test.rb` |
| Crash during work | Reconciliation marks the attempt interrupted. Nothing is rerun automatically. PID fingerprints prevent signalling a reused PID. | AT-07 |
| Reasoning leakage | `thinking` and `reasoning` items are never stored | `providers_test.rb` |

## Licensing (Pro)

- Licences are Ed25519-signed by the vendor. Only public keys ship (`pro/keys/`), and the
  private key never enters the repository. A test key is honoured only under
  `RAILS_ENV=test`.
- Licensing is a commercial control, not a security boundary. The core is MIT and runs
  locally.

## Residual risks (accepted for this release)

- Trusted local execution runs agents as the user, and worktrees are not sandboxes.
  Prefer container isolation (`sandbox.agents: true`) for untrusted work.
- Inside containers agents may use tools without prompts. The boundary is then:
  - internal network with an egress allowlist;
  - read-only root filesystem;
  - all capabilities dropped and no-new-privileges;
  - non-root UID;
  - only the worktree and the git directory mounted.

  The git directory is writable so the agent can commit. Branch protection on the Git host
  remains the control for what reaches shared branches.
- Allowlisted endpoints (provider APIs) are reachable from the container. Data the agent
  reads can therefore reach the provider, which is inherent to using a hosted model.
- Anyone with local shell access as the same OS user can read the SQLite database and the
  runtime token. Use PostgreSQL with restricted credentials for shared machines.
- Redaction relies on patterns. Unknown secret formats can slip through. Add project
  patterns with `config.redaction_patterns`.
- CommandPolicy is a denylist that inspects command text. Obfuscated commands still need
  human approval because the default verdict is "ask", not "allow".
