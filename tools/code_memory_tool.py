"""Agent-native `code_memory` tool — JarvisCopilot's own read/write access to the
shared project code-memory store (same files Claude uses via the MCP server)."""
from __future__ import annotations

import os
import subprocess
from agent import code_memory as cm


def _cwd_slug() -> str:
    try:
        remote = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip() or None
    except Exception:
        remote = None
    return cm.project_slug(os.getcwd(), remote)


def code_memory(action: str, kind: str = "knowledge", entry_type: str = "note",
                content: str = "", project: str | None = None,
                limit: int = 50, name: str = "", root: str = "",
                ts: str = "", query: str = "", ids: list | None = None) -> dict:
    """Read/write the shared project code-memory.

    action: search | get | recall | store | register | list_projects | delete_entry | delete_project
    kind:   knowledge | sessions   (sessions = handoff log)

    Prefer progressive recall: `search` returns compact ranked rows (no bodies),
    then `get ids=[...]` fetches full bodies for the few you need. `recall` returns
    full bodies (use for the conversational browse interface, or small limits).
    """
    slug = project or _cwd_slug()
    try:
        if action == "search":
            return {"slug": slug, "kind": kind,
                    "entries": cm.search(slug, kind=kind, query=query or None, limit=limit)}
        if action == "get":
            return {"entries": cm.get_by_ids(ids or [])}
        if action == "recall":
            return {"slug": slug, "kind": kind,
                    "entries": cm.read_entries(slug, kind, limit=limit)}
        if action == "store":
            return {"ok": True, "slug": slug,
                    **cm.write_entry(slug, kind, entry_type, content)}
        if action == "register":
            return {"ok": True, "entry": cm.register_project(slug, name or slug, root, "")}
        if action == "list_projects":
            return {"projects": cm.list_projects()}
        if action == "delete_entry":
            return {"ok": True, "slug": slug, "removed": cm.delete_entry(slug, kind, ts)}
        if action == "delete_project":
            return {"ok": cm.delete_project(slug), "slug": slug}
        return {"error": f"unknown action {action!r}"}
    except ValueError as e:
        return {"error": str(e)}


# =============================================================================
# OpenAI Function-Calling Schema + Registry
# =============================================================================

CODE_MEMORY_SCHEMA = {
    "name": "code_memory",
    "description": (
        "Read/write the shared project code-memory (durable knowledge + session "
        "handoff), scoped to the current repo. "
        "action: search|get|recall|store|register|list_projects|delete_entry|delete_project. "
        "Progressive recall: `search` (optional `query`) returns COMPACT ranked rows with "
        "ids + one-line summaries (no bodies, token-cheap); then `get` with `ids=[...]` "
        "fetches full bodies for the few you need. `recall` returns full bodies. "
        "kind: knowledge|sessions; "
        "entry_type for knowledge: bug|fix|repo_structure|gotcha|decision|note "
        "(store SHORT declarative facts, one per call); for sessions: claude|jarviscopilot."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["search", "get", "recall", "store", "register", "list_projects", "delete_entry", "delete_project"]},
            "kind": {"type": "string", "enum": ["knowledge", "sessions"]},
            "entry_type": {"type": "string"},
            "content": {"type": "string"},
            "project": {"type": "string"},
            "limit": {"type": "integer"},
            "name": {"type": "string"},
            "root": {"type": "string"},
            "ts": {"type": "string"},
            "query": {"type": "string", "description": "search text (action=search)"},
            "ids": {"type": "array", "items": {"type": "string"}, "description": "entry ids to fetch (action=get)"},
        },
        "required": ["action"],
    },
}

# Remap input_schema → parameters for the registry (OpenAI convention)
_REGISTRY_SCHEMA = {
    "name": CODE_MEMORY_SCHEMA["name"],
    "description": CODE_MEMORY_SCHEMA["description"],
    "parameters": CODE_MEMORY_SCHEMA["input_schema"],
}

from tools.registry import registry

registry.register(
    name="code_memory",
    toolset="code_memory",
    schema=_REGISTRY_SCHEMA,
    handler=lambda args, **_kw: __import__("json").dumps(
        code_memory(
            action=args.get("action", ""),
            kind=args.get("kind", "knowledge"),
            entry_type=args.get("entry_type", "note"),
            content=args.get("content", ""),
            project=args.get("project"),
            limit=args.get("limit", 50),
            name=args.get("name", ""),
            root=args.get("root", ""),
            ts=args.get("ts", ""),
            query=args.get("query", ""),
            ids=args.get("ids"),
        ),
        ensure_ascii=False,
    ),
    emoji="🧠",
)
