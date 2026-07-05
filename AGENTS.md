# AGENTS.md — instructions for AI coding agents working in this repository

This repository is **gh-tower** and it dogfoods its own coordination protocol. You are
expected to follow it (conformance level L2+).

## Coordination protocol (TOWER) — mandatory

1. **Before editing any file**, read the current state:
   `git fetch origin tower-state && git show origin/tower-state:STATUS.md`
   Do NOT modify paths that appear under another actor's active lease.
2. **Claim your task** before working: comment `/claim` on the task's GitHub issue
   (`gh issue comment <N> --body "/claim"`).
   - On Windows/Git-Bash shells, set `MSYS_NO_PATHCONV=1` first, or "/claim" will be
     mangled into a filesystem path.
   - Wait for the coordinator's 🗼 confirmation comment; it tells you your branch name.
3. **Branch naming is structural attribution**: work on `codex/<issue#>-<slug>`
   (agents use their vendor prefix: `codex/`, `claude/`, `copilot/`, `agent/`).
4. **While working**, comment `/heartbeat` at least every 30 minutes on the issue.
5. **Open a PR** referencing the issue (`Closes #N`). Read the 🎯 Conflict Radar comment
   on your PR; if it shows 🔴, the earlier PR in the merge order wins — rebase after it lands.
6. **If CI fails**, read the newest "🔧 Diagnostic Envelope" comment on your PR and fix
   exactly what it lists, on the same branch.
7. **When done or blocked**: comment `/release <one-line context note>` on the issue.

Full spec: [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Development conventions for this repo

- Implementation language is **bash + `gh` + `jq`** (composite actions) — no runtime
  dependencies. Scripts must pass `shellcheck -S warning` and `bash -n`.
- All coordination state is **schema-validated JSON** (`schemas/`); markdown artifacts are
  projections generated from JSON, never sources of truth.
- Machine payloads in comments use versioned HTML tags: `<!-- tower:<kind>:v1 {...} -->`.
  Treat unknown versions as read-only.
- Workflows: keep `permissions:` minimal; job-level `if:` expressions on ONE line
  (multi-line folded scalars have bitten us before).
- CI must stay green: `shellcheck`, JSON-schema validation of `examples/`, `yamllint`,
  `actionlint`, CLI smoke test.
- Update `docs/` in the same PR as behavior changes; the protocol spec and the
  implementation must never drift.
