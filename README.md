# gh-tower 🗼

**A control tower for multi-agent software development — built entirely on GitHub primitives.**

When multiple humans and AI coding agents (Codex, Claude Code, Copilot, anything with a `GITHUB_TOKEN`) work on the *same* repository at the *same* time with overlapping scopes, three things break: they overwrite each other, nobody knows who is touching what, and broken merges land on `main`. gh-tower fixes all three with **zero extra infrastructure** — no server, no database, no message broker. GitHub *is* the message bus.

> Status: **v0.1 — working draft.** Protocol is stable enough to adopt; implementations are early. See [docs/PROTOCOL.md](docs/PROTOCOL.md).

## What it gives any repo

| Capability | How |
|---|---|
| **Task claiming** | `/claim` on any issue → atomic self-assign + intent lease. First writer wins, losers get redirected. |
| **Global visibility** | A `tower-state` branch holds `leases.json` + `activity.json` and a rendered `STATUS.md` — every actor reads *who is touching what* before editing. |
| **Heartbeats** | Humans heartbeat implicitly (pushes, comments = activity). Agents heartbeat explicitly (`repository_dispatch`). A reaper reclaims tasks from silent actors. |
| **Conflict radar** | Every PR gets a sticky comment showing which *other* open PRs and active leases touch the same files — before merge, not after. |
| **Self-healing CI** | Red CI produces a structured **Diagnostic Envelope** (failing tests, logs, suspect paths, machine-parseable JSON). Agent-authored PRs get an automatic `@codex fix` / `@claude fix` routing with a bounded retry budget. |
| **Audit log for free** | The state branch's git history is a tamper-evident record of every claim, heartbeat, and release. |

## How it works

```
 pull main ──► read STATUS.md ──► /claim issue ──► branch ──► code ──► PR
     ▲            (who's on what?)                              │
     │                                                          ▼
     └── pick next task ◄── merge (queue) when green ◄── CI + conflict radar
                                                                │ fail
                                                                ▼
                                       Diagnostic Envelope ──► @agent fix (≤3 tries)
                                                                │ budget exhausted
                                                                ▼
                                                          needs-human label
```

Design rules that make it safe:

1. **Single writer.** Only the coordinator workflow writes the state branch, serialized by an Actions `concurrency` group → race-free by construction.
2. **Advisory leases, mandatory checks.** Leases warn, they don't block (velocity first). Correctness is enforced where it's cheap: CI + (optionally) a merge queue.
3. **Wound-wait negotiation.** On contention: humans outrank agents, then the older claim wins. The younger party rebases, splits, or moves on. No deadlocks, no starvation.
4. **One lease per actor.** No hold-and-wait → circular wait is impossible.
5. **Every message is a GitHub artifact.** Commands are issue comments; machine payloads ride in versioned HTML comments (`<!-- tower:radar:v1 {...} -->`). Humans and agents read the same channel.

## Quickstart (adopting repo)

```bash
gh extension install isobed18/gh-tower   # this repo is also a gh CLI extension
cd your-repo
gh tower init                            # installs the 4 workflows + labels
git add .github && git commit -m "adopt gh-tower" && git push
```

Then, from anywhere:

```bash
gh tower status          # who is doing what (renders STATUS.md)
gh tower claim 42        # claim issue #42 (typed command — no hand-written comments)
gh tower heartbeat 42
gh tower release 42 "auth middleware done, tests missing"
```

Full setup (Projects v2 board, merge queue, agent onboarding): [docs/INSTALL.md](docs/INSTALL.md).

## Dashboard

[`dashboard/index.html`](dashboard/index.html) is a zero-backend live view of any tower-enabled repo —
actors with liveness dots, leases with expiry, open PRs with overlap labels. It reads the
`tower-state` branch via `raw.githubusercontent.com` and the public GitHub API client-side;
host it on GitHub Pages or open it locally: `dashboard/index.html?repo=owner/name`.

## Measuring success

The problem definition and 10 success metrics (red-main rate, overlap caught early, human
wait time, self-heal success rate, …) live in [docs/METRICS.md](docs/METRICS.md) — all
computable from the GitHub API plus the state branch's git history. Baseline a week before
adopting, compare two weeks after.

## Commands

| Comment on an issue/PR | Effect |
|---|---|
| `/claim` | assign yourself, acquire lease (paths read from the issue's `Paths:` line), announce branch |
| `/heartbeat [note]` | refresh activity + renew lease TTL |
| `/release [reason]` | drop lease, unassign, back to Ready with context for the next claimant |
| `/handoff @actor` | release + invite a specific actor |
| `/status` | coordinator replies with the current STATUS.md summary |

## Prior art & positioning

| Project | What it does | Difference |
|---|---|---|
| [github/gh-aw](https://github.com/github/gh-aw) | *Runs* AI agents inside Actions from markdown workflows | gh-tower doesn't run agents — it **coordinates** any number of them (and humans). Complementary: a gh-aw agent can speak tower protocol. |
| GNAP | Git-native agent protocol, JSON files in repo | Same instinct; gh-tower adds single-writer safety, issue-native claiming, conflict radar, and self-heal loops. |
| code-conductor | Label-based issue claiming CLI | Claiming only; no leases/heartbeats/overlap detection. |
| swarm-protocol | MCP server for claims/handoffs | Requires an MCP session; gh-tower is vendor-neutral — anything that can call the GitHub API participates. |

## Repository layout

```
docs/            protocol spec, architecture, install guide
schemas/         JSON Schemas: lease, activity, envelope, command
actions/         composite actions: coordinator, radar, self-heal
templates/       drop-in caller workflows for adopting repos
examples/        valid state-file examples (validated in CI)
```

## License

MIT
