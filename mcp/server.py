"""gh-tower MCP server — typed TOWER-protocol tools for AI agents.

Exposes tower_status / tower_leases / tower_claim / tower_release /
tower_heartbeat / tower_handoff as MCP tools, so agents never compose
protocol comment strings by hand: schema violations become tool-call
errors at the agent boundary instead of silently ignored comments.

All tools shell out to the `gh` CLI, so authentication and identity are
whatever `gh auth status` says — same trust model as a human contributor.

Run (stdio):  python mcp/server.py
Requires:     pip install "mcp[cli]"   and an authenticated `gh`
"""

from __future__ import annotations

import os
import subprocess

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("gh-tower")

STATE_BRANCH = os.environ.get("TOWER_STATE_BRANCH", "tower-state")

# Windows Git-Bash/MSYS mangles arguments starting with "/" into filesystem
# paths ("/claim" -> "C:/Program Files/Git/claim"). Disable for all gh calls.
_ENV = {**os.environ, "MSYS_NO_PATHCONV": "1", "MSYS2_ARG_CONV_EXCL": "*"}


def _gh(*args: str) -> str:
    proc = subprocess.run(
        ["gh", *args], capture_output=True, text=True, env=_ENV, timeout=60
    )
    if proc.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])}… failed: {proc.stderr.strip()}")
    return proc.stdout


def _repo(repo: str) -> str:
    if repo:
        return repo
    return _gh("repo", "view", "--json", "nameWithOwner",
               "--jq", ".nameWithOwner").strip()


def _state_file(repo: str, path: str) -> str:
    import base64
    content = _gh("api", f"repos/{_repo(repo)}/contents/{path}?ref={STATE_BRANCH}",
                  "--jq", ".content")
    return base64.b64decode(content).decode()


def _comment(issue: int, body: str, repo: str) -> str:
    _gh("issue", "comment", str(issue), "-R", _repo(repo), "--body", body)
    return (f"Sent `{body.splitlines()[0]}` to issue #{issue}. The coordinator "
            f"confirms with a 🗼 comment and marks the command with a 👀 reaction; "
            f"check the issue in ~30s.")


@mcp.tool()
def tower_status(repo: str = "") -> str:
    """Who is doing what right now: active actors, leases, and their expiry.

    Read this BEFORE editing any file. Do not modify paths that appear under
    another actor's active lease. `repo` is owner/name; empty = current directory's repo.
    """
    try:
        return _state_file(repo, "STATUS.md")
    except RuntimeError:
        return ("No STATUS.md on the state branch yet — the coordinator has not "
                "run. Plain PR flow applies; still claim before working.")


@mcp.tool()
def tower_leases(repo: str = "") -> str:
    """Raw active leases as JSON (actor, task, paths, mode, expires_at)."""
    try:
        return _state_file(repo, "state/leases.json")
    except RuntimeError:
        return '{"version":1,"leases":[]}'


@mcp.tool()
def tower_claim(issue: int, paths: str = "", repo: str = "") -> str:
    """Claim a task issue before working on it (TOWER protocol step 1).

    Atomically assigns you and acquires an advisory lease. `paths` is an optional
    comma-separated list of files you intend to modify; if omitted, the coordinator
    reads the `Paths:` line from the issue body. After claiming, work on the branch
    name the coordinator's confirmation comment announces.
    """
    body = f"/claim {paths}".strip()
    return _comment(issue, body, repo)


@mcp.tool()
def tower_heartbeat(issue: int, note: str = "", repo: str = "") -> str:
    """Signal liveness while working (send at least every 30 minutes).

    Renews your lease TTL. Silent actors get their tasks reclaimed by the reaper.
    """
    return _comment(issue, f"/heartbeat {note}".strip(), repo)


@mcp.tool()
def tower_release(issue: int, note: str, repo: str = "") -> str:
    """Release a task when done or blocked (TOWER protocol final step).

    `note` is mandatory context for the next claimant: what is done, what remains.
    """
    return _comment(issue, f"/release {note}".strip(), repo)


@mcp.tool()
def tower_handoff(issue: int, to_actor: str, repo: str = "") -> str:
    """Hand a claimed task to a specific actor (releases your lease and invites them)."""
    return _comment(issue, f"/handoff @{to_actor.lstrip('@')}", repo)


if __name__ == "__main__":
    mcp.run()
