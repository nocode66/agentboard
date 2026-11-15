# Releasing AgentBoard

AgentBoard ships as two gems from two repositories:

| Gem | Licence | Published to | How customers install it |
|---|---|---|---|
| `agentboard` (this repository) | MIT | **RubyGems.org** | `gem "agentboard"` |
| `agentboard-pro` (private repository) | Commercial | **Private gem server** on the product site (`https://<site>/gems`) | Scoped `source` block plus their licence as the Bundler credential |

## One-time setup

1. **RubyGems.org.** Create an account and enable MFA. Under *Trusted publishers*, add a
   GitHub Actions publisher for the `agentboard` gem:
   - repository: `<owner>/agentboard`
   - workflow: `release.yml`
   - environment: `rubygems`

   A *pending* trusted publisher can reserve the name before the first release.
2. **GitHub repository settings → Environments:** `rubygems` with required reviewers, so
   every public release is approved by a human.

The commercial gem has its own release workflow and private gem server setup, documented
in its repository.

## Each release

1. Run `bin/test-and-commit` (SQLite and PostgreSQL green). The CI matrix must be green on
   macOS and Linux.
2. Smoke-test every provider listed as `smoke_tested` in the compatibility manifests.
3. Upgrade test (AT-15): add the previous release's last migration version to
   `test/integration/upgrade_test.rb`.
4. Bump `lib/agentboard/version.rb`, then update `CHANGELOG.md`.
5. `git tag vX.Y.Z && git push --tags`. The release workflow then:
   - verifies that the version matches the tag and runs the suite;
   - builds `agentboard` and publishes it to RubyGems.org after the approval.

   `agentboard-pro` follows with the same version, tested against this tag.
6. No destructive migrations in patch releases (spec §23.4). Uploaded gem versions are
   immutable: the server refuses a different file for an existing version.

## How customers install Pro

```ruby
# Gemfile
gem "agentboard", group: :development
source "https://agent-board.live/gems" do
  gem "agentboard-pro", group: :development
end
```

```bash
bundle config set --global agent-board.live "<licence>"   # the key is the hostname, without a port
bundle install
```

- Any licence of a customer in good standing works, so renewals don't break `bundle config`.
- Access ends 14 days after the paid period. Installed gems keep working, and the runtime
  licence has its own grace period.
