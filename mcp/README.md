# gh-tower MCP server

Typed TOWER-protocol tools for AI agents. Instead of composing `/claim` comment strings
(and getting them silently mangled or malformed), agents call schema-validated tools:

| Tool | Purpose |
|---|---|
| `tower_status` | read STATUS.md — who is doing what (call before editing) |
| `tower_leases` | raw leases JSON |
| `tower_claim` | claim an issue + acquire lease |
| `tower_heartbeat` | renew lease / signal liveness |
| `tower_release` | release with a context note |
| `tower_handoff` | hand a task to a specific actor |

Identity and auth come from the ambient `gh auth status` — same trust model as a human.

## Setup

```bash
pip install "mcp[cli]"
gh auth status   # must be logged in
```

**Claude Code:**
```bash
claude mcp add tower -- python /path/to/gh-tower/mcp/server.py
```

**Codex CLI:**
```bash
codex mcp add tower -- python /path/to/gh-tower/mcp/server.py
```

**Any MCP client (stdio):** command `python`, args `["mcp/server.py"]`.

Then instruct the agent (e.g. in `AGENTS.md`): *"Use the tower_* tools: tower_status before
editing, tower_claim before working, tower_heartbeat every 30 min, tower_release when done."*
