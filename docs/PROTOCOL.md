# TOWER Protocol — v1

The TOWER protocol defines how any number of contributors — humans and AI coding agents from any vendor — coordinate concurrent work on a single GitHub repository using only GitHub primitives. An actor is protocol-compliant if it can call the GitHub REST/GraphQL API (or comment on issues); no SDK is required.

## 1. Actors

| Field | Meaning |
|---|---|
| `actor` | GitHub login (humans) or a registered agent id (e.g. `codex-w1`) |
| `actor_type` | `human` \| `agent` |
| branch prefix | every actor pushes branches as `{actor}/{issue#}-{slug}` — attribution is structural |

Agents identify themselves by branch prefix and/or bot login. Every adopting repo lists its known agent prefixes in the self-heal configuration (default: `codex/`, `claude/`, `agent/`, `copilot/`).

## 2. The Ledger (global state)

State lives on an orphan branch (default `tower-state`) containing:

```
state/leases.json      # active intent declarations       (schemas/lease.schema.json)
state/activity.json    # liveness of every actor          (schemas/activity.schema.json)
STATUS.md              # human-readable rendering, regenerated on every change
```

**Single-writer rule.** Only the coordinator workflow may commit to this branch, and all coordinator runs share one Actions `concurrency` group (FIFO, non-cancelling). Every other actor *requests* mutations via commands (§4) or `repository_dispatch` events. This makes the ledger race-free without any locking service, and its git history is the audit log.

**Read path.** Any actor reads state without checkout:
`GET /repos/{o}/{r}/contents/state/leases.json?ref=tower-state` or `git show origin/tower-state:state/leases.json`.

## 3. Leases (intent declarations)

A lease says: *"actor A intends to modify paths P for task T until time E."*

```json
{
  "id": "lease-7f3a",
  "actor": "alice",
  "actor_type": "human",
  "task": 23,
  "branch": "alice/23-negotiation-loop",
  "paths": ["src/agent/negotiation.py", "src/agent/graph.py"],
  "mode": "advisory",
  "acquired_at": "2026-07-06T09:12:00Z",
  "expires_at": "2026-07-06T13:12:00Z",
  "renewals": 1
}
```

Rules:

- `mode: advisory` (default): overlapping leases are **granted with a warning** posted to both actors. Velocity is never blocked; correctness is enforced downstream (radar + CI + merge queue).
- `mode: exclusive`: overlapping requests are queued, not granted. Reserved for paths the repo marks as protected (interface contracts, schema files). Hard TTL 2h.
- Default TTL **4h**, renewed by any heartbeat. Expired leases are removed by the reaper.
- **One lease per actor.** No hold-and-wait ⇒ no deadlock (see §6).
- Paths are declared in the task issue body on a line `Paths: a/b.py, c/` (globs allowed) or as command arguments.

## 4. Commands

Commands are issue/PR comments parsed by the coordinator. Grammar: `/verb [args...]` on the first line; free text after the first line is ignored by machines, read by humans.

| Command | Semantics |
|---|---|
| `/claim [paths...]` | Atomic: if the issue has no assignee → assign commenter, create lease, move project card to In Progress (if configured), reply with confirmation + expected branch name. If already assigned → reply "claimed by X" and suggest open Ready tasks. |
| `/heartbeat [note]` | Update `activity.json.last_seen`, renew lease TTL. |
| `/release [reason]` | Remove lease, unassign, card → Ready. Commenter should leave a context note (what's done / what remains). |
| `/handoff @actor` | `/release` + comment inviting `@actor` to claim. |
| `/status` | Coordinator replies with the current STATUS.md content. |
| `/ack <ruling>` | Acknowledge a negotiation ruling (§6). |

Equivalent event form (for agents that prefer API over comments):

```
POST /repos/{o}/{r}/dispatches
{ "event_type": "tower",
  "client_payload": { "command": "heartbeat", "actor": "codex-w1",
                      "actor_type": "agent", "task": 31 } }
```

Payload schema: `schemas/command.schema.json`.

## 5. Heartbeats & the Reaper

- **Implicit (humans):** any push, PR comment, or review by an actor counts as a heartbeat. Humans working normally never think about the protocol.
- **Explicit (agents):** dispatch a `heartbeat` command at least every **30 min** while holding a lease.
- **Reaper policy** (cron, default `*/15`):
  - lease past `expires_at` → remove + notify on the task issue;
  - assignee silent > **24h** (humans) / > **2h** (agents) → unassign, card → Ready, post a "reclaimed" notice.

A silently parked task is treated as the primary liveness failure, not an edge case.

## 6. Contention & negotiation (wound-wait)

Contention = two actors whose leases or PR diffs intersect.

1. **Ruling is computed, not discussed:** `human > agent`; tie-break by earlier `acquired_at` (or earlier merge-queue position for PRs). The younger party yields.
2. The coordinator posts a **negotiation notice** on both task issues naming the winner and the yielding party's options: **(a)** rebase onto the winner's branch, **(b)** split the task (file a narrower issue), or **(c)** release and claim other work.
3. The yielding party must `/ack` within one heartbeat interval, else the reaper reassigns its task.
4. Two unresolved cycles ⇒ label `needs-human` + (optional) chat webhook escalation. Humans are the supreme court.

Why this can't deadlock: one lease per actor (no hold-and-wait), single-writer state (no split-brain), and wound-wait yields a total order (timestamp, then actor id) ⇒ no circular wait. Yielded tasks keep their original timestamps ⇒ no starvation.

## 7. Conflict radar (pre-merge overlap detection)

On every PR open/push, the radar job:

1. computes the PR's changed files;
2. intersects them with (a) every active lease, (b) the changed files of every *other* open PR;
3. upserts one sticky comment — a file × actor matrix with risk grades: 🟢 disjoint, 🟡 same file, 🔴 same file + both sides modified it heavily — and applies/removes the `overlap:high` label;
4. embeds the machine payload: `<!-- tower:radar:v1 {json} -->`.

The radar never blocks a merge by itself; it feeds humans, agents, and branch-protection rules (a repo may choose to require radar 🟢/🟡 for auto-merge).

## 8. Diagnostic Envelopes (self-healing loop)

On a failed CI `workflow_run` for a PR, the self-heal job posts one structured comment:

```markdown
## 🔧 Diagnostic Envelope — run {id}, attempt {n}/{max}
**Verdict:** FAIL ({summary})
<details><summary>Failing steps — last log lines</summary>…</details>
<!-- tower:envelope:v1 {"run":123,"attempt":2,"max":3,"suspect_paths":[…]} -->
```

Routing:

- PR branch matches an agent prefix ⇒ append a fix instruction mentioning that agent's trigger (e.g. `@codex fix the failures in the envelope above; rebase onto main first.`). The agent pushes to the same branch, CI re-runs — closed loop.
- Human-authored ⇒ envelope only (+ optional chat ping). The human may delegate with one comment.
- **Retry budget: 3 envelopes per PR.** Exhausted ⇒ `needs-human` label, stop mentioning agents. Prevents infinite agent ping-pong and token burn.

## 9. Machine-payload conventions

All machine-parseable data rides in versioned HTML comments inside otherwise human-readable artifacts:

```
<!-- tower:radar:v1 {...} -->   <!-- tower:envelope:v1 {...} -->   <!-- tower:negotiation:v1 {...} -->
```

- The human text and the JSON are generated from the same data; JSON is canonical for machines.
- Unknown versions/tags MUST be treated as read-only by agents.
- Sticky comments are found by tag prefix and edited in place (one radar comment per PR, ever).

## 10. Strictness & trust model

A common misreading: *"the agents communicate through .md files."* They don't. The canonical
substrate is **schema-validated JSON**; markdown is only ever a human-readable *projection* of it:

| Artifact | Canonical form | Markdown role |
|---|---|---|
| Ledger | `state/*.json`, validated against `schemas/*.schema.json` | `STATUS.md` is a rendering, regenerated on every write — never read by machines |
| Commands | `/verb args` grammar (comments) or `command.schema.json` payloads (dispatch) | free text after line 1 is for humans only |
| Radar / envelopes / negotiation | versioned JSON in `<!-- tower:*:v1 {...} -->` | the visible comment is generated *from* the JSON |

Enforcement points, from weakest to strongest:

1. **Write-time validation.** The coordinator rejects dispatch payloads that fail the command
   schema shape before touching state; CI validates state examples against the schemas.
2. **Authenticated identity.** Comment commands inherit the commenter's GitHub identity — it
   cannot be spoofed. Dispatch payloads carry a self-declared `actor` (needed so one bot token
   can host several logical agents, e.g. `codex-w1`, `codex-w2`), but the coordinator records the
   authenticated `sender` login in the state-branch commit message, so impersonation is
   always attributable in the audit log.
3. **Typed interfaces instead of free text.** Humans and scripts should use the `gh tower`
   CLI extension (this repo doubles as one: `gh extension install isobed18/gh-tower`), which
   emits well-formed commands. Roadmap: an **MCP server** exposing `tower_claim`,
   `tower_heartbeat`, `tower_release`, `tower_status` as typed tools — then agents never
   compose comment strings at all, and schema violations become tool-call errors at the
   agent boundary.
4. **Conformance suite (roadmap).** A test harness that replays a scripted actor against a
   sandbox repo and asserts ledger transitions — used to certify an agent integration at a
   given conformance level before it is allowed to hold leases.

## 11. Conformance levels

| Level | Requirement |
|---|---|
| **L0 observer** | reads `tower-state`, never edits without checking leases |
| **L1 participant** | L0 + `/claim` before work, `/release` after, branch naming |
| **L2 citizen** | L1 + heartbeats + `/ack` negotiation rulings |
| **L3 self-healing** | L2 + consumes Diagnostic Envelopes and pushes fixes autonomously |

Humans are L1 by default (implicit heartbeats make them de-facto L2). Agents should be onboarded at L2+ by including this file (or a summary) in their repo-level instructions (`AGENTS.md`, `CLAUDE.md`).
