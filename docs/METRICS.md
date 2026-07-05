# Problem Definition & Success Metrics

## The problem, precisely

**N contributors — humans and AI coding agents from different vendors — modify one repository concurrently, with overlapping scopes that cannot be partitioned into ownership boundaries.**

Without coordination this produces six concrete failure modes:

| # | Failure mode | What it looks like |
|---|---|---|
| F1 | **Lost work** | two actors edit the same logic; the second merge silently reverts or breaks the first |
| F2 | **Broken main** | a PR that was green in isolation breaks against a sibling PR that merged first |
| F3 | **Duplicated effort** | two actors independently implement the same task |
| F4 | **Stalled tasks** | a task is claimed, its actor goes silent, nobody else dares touch it |
| F5 | **Human wait time** | contributors serialize themselves ("push, then wait for your turn") |
| F6 | **Unbounded agent spend** | agents retry/fix in loops with no budget, burning tokens and CI minutes |

gh-tower's claim: F1–F4 become *detected and protocol-resolved*, F5 approaches zero, F6 is bounded by construction.

## Success metrics

Every metric below is computable from data the system already produces (GitHub API + the `tower-state` branch history — the audit log is the metrics store). No extra instrumentation.

| Metric | Definition | Source | Target |
|---|---|---|---|
| **M1 Red-main rate** (F2) | % of default-branch commits whose CI run failed | Actions API | **0%** with merge queue; <5% without |
| **M2 Manual-conflict rate** (F1) | % of merged PRs that needed human conflict resolution | git merge commits + PR timeline | **<10%** |
| **M3 Overlap caught early** (F1) | radar 🔴/🟡 warnings ÷ (warnings + conflicts discovered only at merge) | radar payloads vs. M2 events | **>80%** caught pre-merge |
| **M4 Duplicate-work incidents** (F3) | PRs closed as duplicate / superseded per sprint | PR labels + close reasons | **0–1 per sprint** |
| **M5 Human wait time** (F5) | median time between an actor's PR going "ready" and the actor starting their next task (proxy: gap between last push to PR and first activity on next claim) | activity ledger history | **<10 min** (i.e., nobody idles waiting for merges) |
| **M6 Stalled-task recovery** (F4) | p95 time from last heartbeat of a silent actor to task back in Ready | ledger history (reap commits) | **≤ stale threshold + 15 min** (reaper cron) |
| **M7 Self-heal success rate** (F6-adjacent) | % of red agent PRs that go green within the retry budget without human commits | envelope payloads + subsequent runs | **>60%** |
| **M8 Agent spend bound** (F6) | max envelopes per PR; max concurrent agent workers | envelope counter; conductor config | **≤3; ≤ configured cap** — by construction |
| **M9 Lead time** (overall) | median `/claim` → merged, per task | ledger + PR merge times | trend ↓ over adoption weeks |
| **M10 Protocol adherence** | % of merged PRs whose branch had a matching claim/lease | ledger vs. merged PR list | **>90%** (below that, actors aren't onboarded properly) |

## How to read them together

- **M1–M4 are the integrity story** (does the system prevent the chaos?).
- **M5–M6 are the liveness story** (does it stay fast and unstuck?).
- **M7–M8 are the autonomy story** (do agents repair themselves at bounded cost?).
- **M10 is the adoption canary** — if it drops, fix onboarding (AGENTS.md instructions), not the protocol.

A `tower metrics` CLI subcommand that computes M1–M10 for a date range is on the roadmap; until then each metric's query is one `gh api` + `jq` expression over the sources named above.

## Baseline protocol for adopters

Measure one week *before* enabling tower (most repos can compute M1, M2, M5, M9 retroactively from git/PR history), then compare after two weeks of adoption. If M3 and M5 don't move, tower isn't earning its complexity in your repo — file an issue with your numbers.
