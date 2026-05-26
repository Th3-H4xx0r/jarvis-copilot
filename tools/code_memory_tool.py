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
                limit: int = 50, name: str = "", root: str = "") -> dict:
    """Read/write the shared project code-memory.

    action: recall | store | register | list_projects
    kind:   knowledge | sessions   (sessions = handoff log)
    """
    slug = project or _cwd_slug()
    try:
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
        "action: recall|store|register|list_projects; "
        "kind: knowledge|sessions; "
        "entry_type for knowledge: bug|fix|repo_structure|gotcha|decision|note; "
        "for sessions: claude|jarviscopilot."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["recall", "store", "register", "list_projects"]},
            "kind": {"type": "string", "enum": ["knowledge", "sessions"]},
            "entry_type": {"type": "string"},
            "content": {"type": "string"},
            "project": {"type": "string"},
            "limit": {"type": "integer"},
            "name": {"type": "string"},
            "root": {"type": "string"},
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
        ),
        ensure_ascii=False,
    ),
    emoji="🧠",
)
