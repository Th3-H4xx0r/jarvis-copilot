"""Agent tools to launch and drive Claude Code coding sessions.

Toolset ``coding_sessions``. These wrap ``agent/coding_session_manager.py``
(tmux-backed interactive Claude Code sessions). Registered WITHOUT a check_fn
(like the ``chrome_*`` tools) so they always surface in the catalog; each
handler returns a clean JSON error if the ``claude`` CLI or ``tmux`` is missing.

Registrations are explicit top-level ``registry.register(...)`` calls (NOT a
loop) so ``discover_builtin_tools``'s AST scan picks them up.
"""
from __future__ import annotations

import json
import shutil
from pathlib import Path

from tools.registry import registry

_MGR = None


def _load_memory():
    """Return (memory_text, user_text) from the builtin MEMORY.md / USER.md."""
    try:
        from tools.memory_tool import get_memory_dir

        d = Path(get_memory_dir())
        mem = (d / "MEMORY.md").read_text(encoding="utf-8") if (d / "MEMORY.md").exists() else ""
        usr = (d / "USER.md").read_text(encoding="utf-8") if (d / "USER.md").exists() else ""
        return mem, usr
    except Exception:
        return "", ""


def _mgr():
    global _MGR
    if _MGR is None:
        from agent.coding_session_db import CodingSessionStore
        from agent.coding_host_drivers import LocalDriver
        from agent.coding_session_manager import CodingSessionManager

        from agent.coding_session_capture import wait_for_session_id

        repo = Path(__file__).resolve().parent.parent
        plugin_dir = str(repo / "plugins" / "jarviscopilot-code-assist")
        _MGR = CodingSessionManager(
            store=CodingSessionStore(), driver=LocalDriver(),
            plugin_dir=plugin_dir, memory_loader=_load_memory,
            session_capturer=wait_for_session_id)
    return _MGR


def _store():
    return _mgr().store


def _claude_available() -> bool:
    try:
        from agent.claude_code_client import _resolve_command

        return shutil.which(_resolve_command()) is not None
    except Exception:
        return False


# ── handlers ──────────────────────────────────────────────────────────────────

def _h_launch(args, **kw):
    import os

    a = args or {}
    worktree = bool(a.get("worktree"))
    repo_path = a.get("repo_path")
    # `~`, relative paths, and not-yet-existing dirs are all accepted — the
    # manager expands/absolutizes/creates the dir and preflights the host
    # (auto-installing tmux). We only do a light presence check here.
    if worktree:
        if not repo_path:
            return json.dumps({"error": "worktree=true requires repo_path (a git repo)"})
        cwd = repo_path  # the manager replaces this with the new worktree path
    else:
        cwd = a.get("cwd") or a.get("path")
        if not cwd:
            return json.dumps({"error": "cwd (project directory) is required"})
    model = a.get("model")
    if model:
        from agent.coding_host_drivers import is_valid_model

        if not is_valid_model(model):
            return json.dumps({"error": f"invalid model {model!r} (use opus|sonnet|haiku or a claude-* id)"})
    try:
        s = _mgr().launch(cwd=cwd, title=a.get("title") or "",
                          initial_prompt=a.get("prompt"), model=model,
                          worktree=bool(a.get("worktree")),
                          repo_path=a.get("repo_path"))
        return json.dumps({"ok": True, "session": s})
    except Exception as e:  # pragma: no cover - defensive
        return json.dumps({"error": str(e)})


def _h_list(args, **kw):
    try:
        return json.dumps({"ok": True,
                           "sessions": _mgr().list(status=(args or {}).get("status"))})
    except Exception as e:  # pragma: no cover - defensive
        return json.dumps({"error": str(e)})


def _h_status(args, **kw):
    sid = (args or {}).get("session_id")
    if not sid:
        return json.dumps({"error": "session_id is required"})
    s = _mgr().status(sid)
    if not s:
        return json.dumps({"error": "no such session"})
    return json.dumps({"ok": True, "session": s, "subagents": _mgr().subagents(sid)})


def _h_message(args, **kw):
    a = args or {}
    sid, text = a.get("session_id"), a.get("text")
    if not sid or not text:
        return json.dumps({"error": "session_id and text are required"})
    try:
        _mgr().send_message(sid, text)
        return json.dumps({"ok": True})
    except KeyError:
        return json.dumps({"error": "no such session"})
    except Exception as e:  # pragma: no cover - defensive
        return json.dumps({"error": str(e)})


def _h_stop(args, **kw):
    sid = (args or {}).get("session_id")
    if not sid:
        return json.dumps({"error": "session_id is required"})
    try:
        _mgr().stop(sid)
        return json.dumps({"ok": True})
    except KeyError:
        return json.dumps({"error": "no such session"})
    except Exception as e:  # pragma: no cover - defensive
        return json.dumps({"error": str(e)})


def _h_project_create(args, **kw):
    a = args or {}
    name, repo_path = a.get("name"), a.get("repo_path")
    if not name or not repo_path:
        return json.dumps({"error": "name and repo_path are required"})
    pid = _store().create_project(name=name, repo_path=repo_path,
                                  default_branch=a.get("default_branch"))
    return json.dumps({"ok": True, "project_id": pid})


def _h_project_list(args, **kw):
    return json.dumps({"ok": True, "projects": _store().list_projects()})


# ── schemas ───────────────────────────────────────────────────────────────────

_LAUNCH = {
    "name": "coding_session_launch",
    "description": (
        "Launch an interactive Claude Code coding session in a project directory "
        "on this host (tmux-backed, live-watchable). The session is auto-equipped "
        "with the jarviscopilot-code-assist plugin and seeded with Jarvis memory. "
        "Use when the user asks to start a coding agent on a project/task."),
    "parameters": {"type": "object",
                   "properties": {
                       "cwd": {"type": "string", "description": "absolute path to the project directory"},
                       "title": {"type": "string", "description": "short human label for the session"},
                       "prompt": {"type": "string", "description": "the initial task/instruction for the session"},
                       "model": {"type": "string", "description": "claude model (opus|sonnet|haiku or a full id)"},
                       "worktree": {"type": "boolean", "description": "isolate in a fresh git worktree (requires repo_path)"},
                       "repo_path": {"type": "string", "description": "repo to branch a worktree from when worktree=true"}},
                   "required": ["cwd"]},
}
_LIST = {
    "name": "coding_session_list",
    "description": "List coding sessions Jarvis is tracking (optionally filtered by status).",
    "parameters": {"type": "object",
                   "properties": {"status": {"type": "string",
                                             "description": "optional: starting|running|idle|stopped|error"}}},
}
_STATUS = {
    "name": "coding_session_status",
    "description": "Get the status/metadata of one coding session by id.",
    "parameters": {"type": "object",
                   "properties": {"session_id": {"type": "string"}},
                   "required": ["session_id"]},
}
_MESSAGE = {
    "name": "coding_session_message",
    "description": ("Send a message/instruction into a running coding session "
                    "(types it into the session and submits). Use to relay the "
                    "user's follow-up like 'tell session X to also fix the tests'."),
    "parameters": {"type": "object",
                   "properties": {"session_id": {"type": "string"},
                                  "text": {"type": "string", "description": "the message to send"}},
                   "required": ["session_id", "text"]},
}
_STOP = {
    "name": "coding_session_stop",
    "description": "Stop a coding session (kills its tmux session).",
    "parameters": {"type": "object",
                   "properties": {"session_id": {"type": "string"}},
                   "required": ["session_id"]},
}
_PROJECT_CREATE = {
    "name": "coding_project_create",
    "description": "Register a coding project (a named repo directory sessions can run in).",
    "parameters": {"type": "object",
                   "properties": {
                       "name": {"type": "string"},
                       "repo_path": {"type": "string", "description": "absolute path to the repo"},
                       "default_branch": {"type": "string"}},
                   "required": ["name", "repo_path"]},
}
_PROJECT_LIST = {
    "name": "coding_project_list",
    "description": "List registered coding projects.",
    "parameters": {"type": "object", "properties": {}},
}


# Explicit top-level registrations (NOT a loop — discover_builtin_tools' AST scan
# only sees literal top-level registry.register(...) calls).
registry.register(name="coding_session_launch", toolset="coding_sessions",
                  schema=_LAUNCH, handler=_h_launch, emoji="🚀")
registry.register(name="coding_session_list", toolset="coding_sessions",
                  schema=_LIST, handler=_h_list, emoji="📋")
registry.register(name="coding_session_status", toolset="coding_sessions",
                  schema=_STATUS, handler=_h_status, emoji="ℹ️")
registry.register(name="coding_session_message", toolset="coding_sessions",
                  schema=_MESSAGE, handler=_h_message, emoji="✉️")
registry.register(name="coding_session_stop", toolset="coding_sessions",
                  schema=_STOP, handler=_h_stop, emoji="🛑")
registry.register(name="coding_project_create", toolset="coding_sessions",
                  schema=_PROJECT_CREATE, handler=_h_project_create, emoji="🗂️")
registry.register(name="coding_project_list", toolset="coding_sessions",
                  schema=_PROJECT_LIST, handler=_h_project_list, emoji="🗂️")
