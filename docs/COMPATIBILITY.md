# Compatibility matrix (0.2.0)

## Platforms

| | Status |
|---|---|
| macOS (arm64), Ruby 4.0, Rails 8.1 | Tested locally: full suite on SQLite and PostgreSQL 17, real Claude Code smoke test |
| Linux and macOS, Ruby 3.3 / 3.4 / 4.0 | CI matrix (`.github/workflows/ci.yml`) |
| Rails 7.2 | Supported by the gemspec; not yet exercised in CI |
| Windows | Not supported (POSIX process groups, Unix sockets) |

## Container isolation

| Runtime | Status |
|---|---|
| Docker (Desktop on macOS, Engine on Linux), Podman (`sandbox.runtime: podman`) | Flow tested with a simulated runtime (argv, network, proxy, cancellation, verification). Live run pending. |
| Egress proxy | Allowlisting CONNECT proxy in `lib/agentboard/egress_proxy.rb`; tested in-process |

## Git hosting (Pro)

| Host | Webhook auth | Events | PR/MR creation |
|---|---|---|---|
| GitHub | HMAC-SHA256 `X-Hub-Signature-256` | `pull_request` | `gh pr create` |
| GitLab (gitlab.com or self-managed `base_url`) | `X-Gitlab-Token` | Merge Request Hook | REST API v4 (`PRIVATE-TOKEN`) |
| Bitbucket Cloud | HMAC-SHA256 `X-Hub-Signature` | `pullrequest:*` | REST API 2.0 (Bearer token); 12-char SHAs are resolved locally |

Payload handling is covered by fixture tests. None of the hosts has been tested against a live repository yet.
| Databases | PostgreSQL (recommended), SQLite (single-user development) |

## Providers

| Provider | Version | Passive | Active | Status |
|---|---|---|---|---|
| Claude Code | 2.1.325 | MCP, lifecycle hooks | `-p --output-format stream-json`, resume, permission bridge | **smoke_tested**: end-to-end implement, verify and review, plus a real permission request and expiry |
| OpenAI Codex | 0.156.1 | MCP (`codex mcp add`), opt-in `notify` | `exec --json` | flags_checked. Real failure-path fixture captured. A success run was blocked by the account's model policy. |
| Cursor | any | `.cursor/mcp.json` | — | passive only |
| Gemini CLI, OpenCode, Copilot | any | MCP detection only | — | P2 placeholders |

Versions that are not in `lib/agentboard/providers/compatibility/*.yml` get only
conservative capabilities (AT-14). Opt in per provider with `allow_unvalidated_versions: true`.
