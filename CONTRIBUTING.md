# Contributing

This repo uses the TOWER coordination protocol for every contribution, whether
the contributor is human or an AI coding agent. Read `docs/PROTOCOL.md` before
starting work.

## Coordination

Before editing files:

1. Read the current tower state:
   `git fetch origin tower-state && git show origin/tower-state:STATUS.md`.
2. Claim the GitHub issue with `/claim` and wait for the coordinator's
   confirmation comment.
3. Work on the branch name announced by the coordinator, using the appropriate
   actor prefix such as `codex/`, `claude/`, `copilot/`, or your GitHub login.

While working:

- Do not modify paths covered by another active lease.
- Send `/heartbeat` at least every 30 minutes while holding a lease.
- If a negotiation or conflict-radar ruling appears, follow `docs/PROTOCOL.md`.

When finished or blocked:

- Open a PR that references the issue, for example `Closes #4`.
- Release the lease with `/release <context>`, briefly stating what changed or
  what remains.

## Development Conventions

- Use Bash, `gh`, and `jq`; avoid adding runtime dependencies.
- Keep shell scripts clean with `shellcheck -S warning` and `bash -n`.
- Keep workflow permissions minimal.
- Keep job-level `if:` expressions on one line.
- Use schema-validated JSON as canonical coordination state; markdown artifacts
  are generated projections.
- Use versioned HTML tags for machine payloads, such as
  `<!-- tower:<kind>:v1 {...} -->`.
- Treat unknown machine-payload versions as read-only.
- Update `docs/` in the same PR as behavior changes so the protocol and
  implementation do not drift.

## Before Opening a PR

- Confirm only the intended files changed.
- Run the relevant checks when touching scripts, workflows, schemas, or examples.
- Include enough context in the PR body for reviewers to connect the change to
  the issue.
