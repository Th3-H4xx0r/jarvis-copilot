"""Server-side ``jarviscopilot-code-assist`` MCP server (stdio).

This is the SERVER-host counterpart to the desktop's ``jc-client mcp-serve``
(``desktop_client/jc_client/mcp_server.py``). It offers the SAME code-assist
tools — one definition, ``desktop_client/jc_client/code_assist_mcp.py``, loaded
by path — to a launched ``claude`` session, but instead of reaching hermes over
the desktop's paired pinned connection its implementations talk to the LOCAL
code-memory store (``agent.code_memory``) directly — because a server-host
session's claude is already running ON hermes.

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

from agent import code_memory
from agent.agent_engine_shim import load_code_assist_mcp, load_code_memory_slug

code_memory_slug = load_code_memory_slug()


# ── project-slug resolution (cwd-based, like the desktop client) ──────────────

def _git_remote(root: str) -> str:
    return code_memory_slug.git_remote(root)


def _current_slug(project: str = "") -> str:
    """Slug for the project: explicit ``project`` wins, else derive from cwd."""
    if project:
        return project
    return code_memory_slug.current_slug()


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
    """Read JarvisCopilot's general memory (MEMORY.md / USER.md) from the active profile's
    builtin store (``memories/``, or its root on older installs)."""
    try:
        from jarviscopilot_constants import get_hermes_home

        home = str(get_hermes_home())
        candidates = [os.path.join(home, "memories"), home]
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

# The tool names, arguments and descriptions are jc-client's code_assist_mcp
# (loaded by path), shared with the desktop's ``jc-client mcp-serve``. This host
# has no ``ask`` / ``run_skill``, so those tools are not offered here.
SERVER_BACKEND = {
    "register_project": _register_project,
    "store_code_knowledge": _store_code_knowledge,
    "recall_code_knowledge": _recall_code_knowledge,
    "get_code_knowledge": _get_code_knowledge,
    "edit_code_memory": _edit_code_memory,
    "delete_code_memory": _delete_code_memory,
    "store_session_handoff": _store_session_handoff,
    "recall_session_handoff": _recall_session_handoff,
    "query_memory": _query_memory,
}


def build_server():
    return load_code_assist_mcp().build_server(SERVER_BACKEND)


def main() -> None:
    """Entry point for ``python3 -m agent.coding_mcp_server`` (stdio transport)."""
    build_server().run()


if __name__ == "__main__":
    main()
