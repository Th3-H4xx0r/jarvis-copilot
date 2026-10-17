"""Agent tools to launch and drive coding-agent sessions from a Jarvis chat.

Toolset ``coding_sessions``. These drive the Agents conversation layer
(``webui/api/agents_core.py``): sessions run as Claude Code background sessions
on the server, Mac sessions are reached through jc-client, and every message
reports whether it was delivered. A session id is the conversation key
(``claude|<session id>``); a bare session id is taken as a Claude one.

Registrations are explicit top-level ``registry.register(...)`` calls (NOT a
loop) so ``discover_builtin_tools``'s AST scan picks them up.
"""
from __future__ import annotations

import json

from tools.registry import registry

_NO_CORE = ("Coding sessions are run by the Jarvis app's server (the Agents tab); "
            "they aren't available from here.")


def _core():
    try:
        from api.agents_core import core
        return core()
    except Exception:
        return None


def _store():
    from agent.coding_session_db import CodingSessionStore
    return CodingSessionStore()


def _ckey(sid: str) -> str:
    sid = str(sid or "").strip()
    return sid if "|" in sid else f"claude|{sid}"


def _valid_model(name: str) -> bool:
    try:
        from agent.claude_code_client import _looks_like_claude_model
        return _looks_like_claude_model(name)
    except Exception:
        return False


# ── handlers ──────────────────────────────────────────────────────────────────

def _h_launch(args, **kw):
    a = args or {}
    cwd = a.get("cwd") or a.get("path") or a.get("repo_path")
    if not cwd:
        return json.dumps({"error": "cwd (project directory) is required"})
    model = a.get("model")
    if model and not _valid_model(model):
        return json.dumps({"error": f"invalid model {model!r} (use opus|sonnet|haiku or a claude-* id)"})
    c = _core()
    if c is None:
        return json.dumps({"error": _NO_CORE})
    body = {"cwd": cwd, "where": a.get("where") or "server", "agent": a.get("agent") or "claude",
            "prompt": a.get("prompt"), "model": model,
            "permission_mode": "bypassPermissions" if a.get("skip_permissions") else None}
    out = c.launch({k: v for k, v in body.items() if v is not None})
    return json.dumps(out if not out.get("ok") else {"ok": True, "launched": body["cwd"]})


def _h_list(args, **kw):
    c = _core()
    if c is None:
        return json.dumps({"error": _NO_CORE})
    data = c.list_payload()
    rows = list(data.get("needs_you") or [])
    for p in data.get("projects") or []:
        rows += [dict(s, project=s.get("project") or p.get("name")) for s in p.get("sessions") or []]
    keep = ("ckey", "title", "project", "agent", "owner_name", "status", "state", "step")
    return json.dumps({"ok": True, "sessions": [{k: r.get(k) for k in keep if k in r} for r in rows],
                       "mac_asleep": data.get("card")})


def _h_status(args, **kw):
    sid = (args or {}).get("session_id")
    if not sid:
        return json.dumps({"error": "session_id is required"})
    c = _core()
    if c is None:
        return json.dumps({"error": _NO_CORE})
    row = c.conv.get(_ckey(sid))
    if not row:
        return json.dumps({"error": "no such session"})
    return json.dumps({"ok": True, "session": row}, default=str)


def _h_message(args, **kw):
    a = args or {}
    sid, text = a.get("session_id"), a.get("text")
    if not sid or not text:
        return json.dumps({"error": "session_id and text are required"})
    c = _core()
    if c is None:
        return json.dumps({"error": _NO_CORE})
    d = c.handoff.send(_ckey(sid), str(text))
    return json.dumps({"ok": d.get("state") != "failed", "delivery": d})


def _h_stop(args, **kw):
    sid = (args or {}).get("session_id")
    if not sid:
        return json.dumps({"error": "session_id is required"})
    c = _core()
    if c is None:
        return json.dumps({"error": _NO_CORE})
    return json.dumps(c.stop(_ckey(sid)))


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
        "Start a Claude Code session in a project folder on the server (a background "
        "session the user can watch and drive from the Agents tab). "
        "Use when the user asks to start a coding agent on a project/task."),
    "parameters": {"type": "object",
                   "properties": {
                       "cwd": {"type": "string", "description": "absolute path to the project directory"},
                       "title": {"type": "string", "description": "short human label for the session"},
                       "prompt": {"type": "string", "description": "the initial task/instruction for the session"},
                       "model": {"type": "string", "description": "claude model (opus|sonnet|haiku or a full id)"},
                                                                     "skip_permissions": {"type": "boolean", "description": "run claude with --dangerously-skip-permissions (no approval prompts; autonomous)"}},
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
    "description": "Stop a coding session.",
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
