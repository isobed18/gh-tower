# Installing gh-tower in a repository

## Prerequisites

- A GitHub repository (public or private) with Actions enabled.
- `gh` CLI for the one-time setup (or do the same steps in the UI).

## 1. Drop in the caller workflows

Copy the four templates into `.github/workflows/` of your repo:

```bash
for f in tower-coordinator tower-radar tower-reaper tower-self-heal; do
  curl -fsSL "https://raw.githubusercontent.com/isobed18/gh-tower/main/templates/$f.yml" \
       -o ".github/workflows/$f.yml"
done
```

Pin the action version by editing `uses: isobed18/gh-tower/actions/...@main` to a tag once releases exist.

## 2. Labels

```bash
gh label create overlap:high --color D93F0B --description "PR collides with in-flight work"
gh label create needs-human  --color B60205 --description "self-heal budget exhausted"
gh label create protocol-violation --color FBCA04 --description "edited without a claim/lease"
```

## 3. Permissions

The default `GITHUB_TOKEN` is enough for everything the templates do (they request
`contents: write` for the state branch, `issues: write`, `pull-requests: write`).
No PAT is required unless you want the coordinator to act under a dedicated bot identity.

**Note on `GITHUB_TOKEN` push loops:** pushes made with the default token do not trigger
other workflows — which is exactly what we want for state-branch commits (no recursion).

## 4. Recommended (not required) repo settings

| Setting | Why |
|---|---|
| Branch ruleset on `main`: PRs only + required checks | keeps `main` green regardless of who/what pushes |
| **Merge queue** (org-owned public repos, or Enterprise) | tests each PR against main + PRs ahead of it → catches semantic conflicts between overlapping work. This is the strongest guardrail gh-tower assumes may exist. |
| Auto-merge enabled | with "require branches up to date" this is the poor-man's queue on personal repos |
| Projects v2 board with Ready/In Progress columns | gives `/claim` a card to move (optional; tower works without it) |

## 5. Onboard your agents

Add a short section to your repo's `AGENTS.md` / `CLAUDE.md`:

```markdown
## Coordination protocol (gh-tower)
Before editing any file:
1. Read `origin/tower-state:STATUS.md` — do not modify paths under an active lease you don't hold.
2. Claim your task: comment `/claim` on its issue. Branch as `{you}/{issue#}-{slug}`.
3. While working, send `/heartbeat` at least every 30 min (or repository_dispatch "tower" events).
4. If CI fails on your PR, read the latest "Diagnostic Envelope" comment and fix exactly what it lists.
5. When done or blocked: `/release <context note>`.
Full spec: https://github.com/isobed18/gh-tower/blob/main/docs/PROTOCOL.md
```

## 6. Configuration reference (template inputs)

| Input | Default | Meaning |
|---|---|---|
| `state-branch` | `tower-state` | orphan branch holding the ledger |
| `lease-ttl-minutes` | `240` | advisory lease lifetime |
| `agent-stale-minutes` | `120` | reaper reclaim threshold for agents |
| `human-stale-minutes` | `1440` | reaper reclaim threshold for humans |
| `agent-branch-prefixes` | `codex/,claude/,agent/,copilot/` | how self-heal recognizes agent PRs |
| `fix-mention` | `@codex` | who gets asked to fix agent PRs |
| `max-heal-attempts` | `3` | envelope retry budget per PR |
| `sweep-window-minutes` | `360` | how far back the reaper's sweeper replays unacknowledged (no-👀) commands |
| `project-number` / `project-owner` / `project-token` | unset | EXPERIMENTAL: move Projects v2 cards to *In Progress* / *Ready* on claim/release. Needs a PAT with `project` scope — `GITHUB_TOKEN` cannot access Projects v2. |

## 7. Kill switch

Set a repository variable `TOWER_ENABLED=false` to short-circuit all tower workflows.
The repo instantly degrades to plain PR flow; nothing else breaks.
