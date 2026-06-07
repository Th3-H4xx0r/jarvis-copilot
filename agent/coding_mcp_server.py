"""Server-side ``jarviscopilot-code-assist`` MCP server (stdio).

This is the SERVER-host counterpart to the desktop's ``jc-client mcp-serve``
(``desktop_client/jc_client/mcp_server.py``). It exposes the SAME code-assist
tools to a launched ``claude`` session, but instead of reaching hermes over the
desktop's paired pinned connection it talks to the LOCAL code-memory store
(``agent.code_memory``) directly — because a server-host session's claude is
already running ON hermes.

Why this exists
---------------
The plugin used to declare its MCP server as ``jc-client mcp-serve`` for every
host. ``jc-client`` is the DESKTOP binary and isn't installed on the server, so a
server-host session's claude hit ``ENOENT`` and showed the MCP as "✗ failed".
The coding-session manager now writes a per-session ``.mcp.json`` that points a
server-host session at this module (``python3 -m agent.coding_mcp_server``).

Run with: ``python3 -m agent.coding_mcp_server`` (cwd = the project dir, so the
project slug is derived from it; ``PYTHONPATH`` must include the JarvisCopilot
repo root so ``agent`` is importable).
"""
from __future__ import annotations

import os
import subprocess

from agent import code_memory


# ── project-slug resolution (cwd-based, like the desktop client) ──────────────

def _git_remote(root: str) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", root, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5)
        if out.returncode == 0:
            return (out.stdout or "").strip()
    except Exception:
        pass
    return ""


def _current_slug(project: str = "") -> str:
    """Slug for the project: explicit ``project`` wins, else derive from cwd."""
    if project:
        return project
    root = os.getcwd()
    return code_memory.project_slug(root, _git_remote(root))


# ── tool implementations (plain functions, unit-testable) ─────────────────────

def _register_project(name: str, root: str = "", remote: str = "") -> dict:
    try:
        r = root or os.getcwd()
        slug = code_memory.project_slug(r, remote or _git_remote(r))
        return code_memory.register_project(slug, name or slug, r, remote or _git_remote(r))
    except Exception as e:  # noqa: BLE001 — tools must never raise into MCP
        return {"error": str(e)}


def _store_code_knowledge(entry_type: str, content: str, project: str = "") -> dict:
    try:
        slug = _current_slug(project)
        return code_memory.write_entry(slug, "knowledge", entry_type, content)
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}


def _recall_code_knowledge(project: str = "", query: str = "", limit: int = 20) -> str:
    try:
        slug = _current_slug(project)
        rows = code_memory.search(slug, "knowledge", query=query or None, limit=limit)
        if not rows:
            return "(no matching knowledge yet)"
        lines = [f"{r.get('id','')}  [{r.get('entry_type','')}] {r.get('first_line','')}"
                 for r in rows]
        return ("Compact matches (id  [type]  summary). Call get_code_knowledge(ids=[...]) "
                "to read the full body of the FEW you actually need — don't fetch them all:\n"
                + "\n".join(lines))
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


def _get_code_knowledge(ids) -> str:
    try:
        if isinstance(ids, str):
            ids = [i.strip() for i in ids.split(",") if i.strip()]
        rows = code_memory.get_by_ids(list(ids or []))
        if not rows:
            return "(no entries for those ids)"
        return "\n\n".join(
            f"[{r.get('entry_type','')}] ({r.get('ts','')})\n{r.get('content','')}" for r in rows)
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


def _store_session_handoff(content: str, project: str = "") -> dict:
    try:
        slug = _current_slug(project)
        return code_memory.write_entry(slug, "sessions", "claude", content)
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}


def _recall_session_handoff(project: str = "", limit: int = 3) -> str:
    try:
        slug = _current_slug(project)
        rows = code_memory.read_entries(slug, "sessions", limit=limit)
        return "\n\n".join(f"{r.get('id','')}  [{r.get('ts','')}]\n{r.get('content','')}"
                           for r in rows) or "(no prior sessions)"
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


def _edit_code_memory(eid: str, content: str, entry_type: str = "") -> dict:
    try:
        return code_memory.update_by_id(eid, content, entry_type or None)
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}


def _delete_code_memory(eid: str) -> dict:
    try:
        ok = code_memory.delete_by_id(eid)
        return {"deleted": bool(ok), "id": eid}
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}


def _query_memory(query: str = "") -> str:
    """Read JarvisCopilot's general memory (MEMORY.md / USER.md) from the local
    builtin store. Best-effort across the known locations."""
    try:
        home = os.path.expanduser("~")
        candidates = [
            os.path.join(home, ".jarviscopilot", "memories"),
            os.path.join(home, ".jarviscopilot"),
        ]
        text = ""
        for base in candidates:
            mem = os.path.join(base, "MEMORY.md")
            usr = os.path.join(base, "USER.md")
            if os.path.isfile(mem) or os.path.isfile(usr):
                parts = []
                for p in (mem, usr):
                    try:
                        with open(p, encoding="utf-8") as fh:
                            parts.append(fh.read())
                    except OSError:
                        pass
                text = "\n\n".join(parts).strip()
                break
        if not text:
            return "(no general memory found)"
        if query:
            filtered = "\n".join(ln for ln in text.splitlines()
                                 if query.lower() in ln.lower())
            text = filtered or text
        return text[:20000] or "(empty)"
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


# ── MCP server assembly ───────────────────────────────────────────────────────

def build_server():
    from mcp.server.fastmcp import FastMCP
    mcp = FastMCP("jarviscopilot-code-assist")

    @mcp.tool()
    def register_project(name: str, root: str = "", remote: str = "") -> dict:
        """Register the current project with JarvisCopilot's code-memory (by git remote/dir slug)."""
        return _register_project(name, root, remote)

    @mcp.tool()
    def store_code_knowledge(entry_type: str, content: str, project: str = "") -> dict:
        """Store ONE durable coding fact for this project. entry_type: bug|fix|repo_structure|gotcha|decision|note.

        Keep it SHORT — a 1-3 sentence declarative fact (~400 chars), one fact per call.
        Store proactively when you fix a non-obvious bug, learn repo structure, hit a
        gotcha, make a decision, or find an approach works/fails. Do NOT store run-specific
        results, dated verdicts, PR/commit SHAs, or anything stale within a week — those go
        in a session handoff, not knowledge. Returns a `warning` if the entry is too long."""
        return _store_code_knowledge(entry_type, content, project)

    @mcp.tool()
    def recall_code_knowledge(project: str = "", query: str = "", limit: int = 20) -> str:
        """Search this project's durable coding knowledge. Returns COMPACT ranked rows
        (id + type + one-line summary), token-cheap. Pass `query` to rank by relevance.
        Then call get_code_knowledge(ids=[...]) to read the full body of only the few you
        need. Prefer this over dumping everything."""
        return _recall_code_knowledge(project, query, limit)

    @mcp.tool()
    def get_code_knowledge(ids: list[str]) -> str:
        """Fetch the FULL bodies of specific knowledge entries by their ids (from
        recall_code_knowledge). Fetch only the ids you actually need."""
        return _get_code_knowledge(ids)

    @mcp.tool()
    def edit_code_memory(id: str, content: str, entry_type: str = "") -> dict:
        """Edit an existing entry IN PLACE by its id (ids come from
        recall_code_knowledge / recall_session_handoff). Replaces its content — and
        entry_type if given (knowledge: bug|fix|repo_structure|gotcha|decision|note) —
        while preserving its timestamp. Prefer this over storing a near-duplicate when
        correcting or shortening a fact."""
        return _edit_code_memory(id, content, entry_type)

    @mcp.tool()
    def delete_code_memory(id: str) -> dict:
        """Delete a single code-memory entry by its id (from recall_code_knowledge /
        recall_session_handoff). Precise — removes only that entry. Use for stale,
        wrong, or duplicate entries."""
        return _delete_code_memory(id)

    @mcp.tool()
    def store_session_handoff(content: str, project: str = "") -> dict:
        """Store a session handoff (what was done, current state, open threads)."""
        return _store_session_handoff(content, project)

    @mcp.tool()
    def recall_session_handoff(project: str = "", limit: int = 3) -> str:
        """Recall the latest session handoff(s) for this project."""
        return _recall_session_handoff(project, limit)

    @mcp.tool()
    def query_memory(query: str = "") -> str:
        """Read JarvisCopilot's general memory (MEMORY.md / USER.md)."""
        return _query_memory(query)

    return mcp


def main() -> None:
    """Entry point for ``python3 -m agent.coding_mcp_server`` (stdio transport)."""
    build_server().run()


if __name__ == "__main__":
    main()
