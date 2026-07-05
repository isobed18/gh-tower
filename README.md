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
# 1. copy the caller workflows into your repo
curl -fsSL https://raw.githubusercontent.com/isobed18/gh-tower/main/templates/tower-coordinator.yml -o .github/workflows/tower-coordinator.yml
curl -fsSL https://raw.githubusercontent.com/isobed18/gh-tower/main/templates/tower-radar.yml       -o .github/workflows/tower-radar.yml
curl -fsSL https://raw.githubusercontent.com/isobed18/gh-tower/main/templates/tower-reaper.yml      -o .github/workflows/tower-reaper.yml
curl -fsSL https://raw.githubusercontent.com/isobed18/gh-tower/main/templates/tower-self-heal.yml   -o .github/workflows/tower-self-heal.yml

# 2. create the labels tower uses
gh label create overlap:high --color D93F0B --description "PR collides with in-flight work"
gh label create needs-human  --color B60205 --description "self-heal budget exhausted"

# 3. done. Comment /claim on any issue.
```

Full setup (Projects v2 board, merge queue, agent onboarding): [docs/INSTALL.md](docs/INSTALL.md).

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
