"""Pure HTTP dispatcher for JarvisCopilot's Coding Sessions WebUI API.

The single public entry point, :func:`handle_coding_request`, is a *pure*
function decoupled from the ``http.server`` plumbing: it takes the method,
the path (already stripped to the part after ``/api/coding``), the parsed
JSON body, and a ``CodingSessionManager`` (injected, so tests pass a fake —
no real claude/tmux/git), and returns ``(status_code, payload_dict)``.

The wiring in ``routes.py`` adapts that tuple to the wire with
``j(handler, payload, status=status)``.

Contract (``<path>`` is what follows ``/api/coding``)::

    GET  /projects                      -> 200 {"projects": [...]}
    POST /projects {name, repo_path,
                    default_branch?}     -> 200 {"ok": True, "project_id": id}
    GET  /sessions [?status=]            -> 200 {"sessions": [...]}
    POST /launch {cwd?, repo_path?,
                  worktree?, title?,
                  prompt?, model?}       -> 200 {"ok": True, "session": {...}}
    GET  /session/<id>                   -> 200 {"ok": True, "session": {...},
                                                 "subagents": [...]}
    POST /session/<id>/message {text}    -> 200 {"ok": True}
    POST /session/<id>/stop              -> 200 {"ok": True}

Errors: 400 on validation, 404 on unknown session / route (and on
``KeyError`` bubbling out of the manager), 500 on any other manager
exception (with ``{"error": str(e)}``).
"""
from __future__ import annotations

from urllib.parse import parse_qs, urlsplit

CODING_PATH_PREFIX = "/api/coding"

_MANAGER = None


def default_manager():
    """The shared CodingSessionManager (same singleton the chat tools use).

    Lazily built so importing this module is cheap and the webui only spins up
    a LocalDriver manager when a /api/coding/* request actually arrives.
    """
    global _MANAGER
    if _MANAGER is None:
        from tools.coding_session_tool import _mgr

        _MANAGER = _mgr()
    return _MANAGER


def matches(path: str) -> bool:
    """True when *path* is routed to this module (under the coding prefix)."""
    return bool(path) and path.startswith(CODING_PATH_PREFIX)


# ── helpers ─────────────────────────────────────────────────────────────────────

def _split_path(path: str) -> tuple[str, dict]:
    """Return (path_without_query, query_dict) for the sub-path."""
    parts = urlsplit(path or "")
    query = {k: v[0] for k, v in parse_qs(parts.query).items()}
    p = parts.path or ""
    # Normalise a trailing slash (but keep the bare "" / "/" distinguishable
    # only as far as routing cares — every concrete route has a non-empty tail).
    if len(p) > 1 and p.endswith("/"):
        p = p.rstrip("/")
    return p, query


def _ok(payload: dict) -> tuple[int, dict]:
    return 200, payload


def _err(status: int, msg: str) -> tuple[int, dict]:
    return status, {"error": msg}


def _run(fn) -> tuple[int, dict]:
    """Invoke a manager call, mapping exceptions to status codes.

    ``KeyError`` (unknown session id from the manager) -> 404; any other
    exception -> 500. ``fn`` returns the success ``(status, payload)`` tuple.
    """
    try:
        return fn()
    except KeyError as e:
        # KeyError("x").args[0] == "x"; str(KeyError("x")) == "'x'".
        msg = str(e.args[0]) if e.args else "not found"
        return _err(404, msg)
    except Exception as e:  # noqa: BLE001 — surface the message to the client
        return _err(500, str(e))


# ── dispatcher ──────────────────────────────────────────────────────────────────

def handle_coding_request(method: str, path: str, body: dict | None, *,
                          manager) -> tuple[int, dict]:
    """Route a single coding-API request. See module docstring for the contract."""
    method = (method or "").upper()
    body = body or {}
    p, query = _split_path(path)

    # ── /projects ──
    if p == "/projects":
        if method == "GET":
            return _run(lambda: _ok({"projects": manager.store.list_projects()}))
        if method == "POST":
            name = (body.get("name") or "").strip()
            repo_path = (body.get("repo_path") or "").strip()
            if not name or not repo_path:
                return _err(400, "name and repo_path are required")
            default_branch = body.get("default_branch") or None

            def _create():
                pid = manager.store.create_project(
                    name=name, repo_path=repo_path, default_branch=default_branch)
                return _ok({"ok": True, "project_id": pid})

            return _run(_create)
        return _err(404, "not found")

    # ── /sessions ──
    if p == "/sessions":
        if method == "GET":
            status = query.get("status") or None
            return _run(lambda: _ok({"sessions": manager.list(status=status)}))
        return _err(404, "not found")

    # ── /launch ──
    if p == "/launch":
        if method == "POST":
            worktree = bool(body.get("worktree"))
            repo_path = body.get("repo_path")
            cwd = body.get("cwd")
            if worktree:
                if not repo_path:
                    return _err(400, "worktree=true requires repo_path")
            else:
                if not cwd:
                    return _err(400, "cwd is required (or set worktree=true with repo_path)")

            def _launch():
                session = manager.launch(
                    cwd=cwd, title=body.get("title"),
                    initial_prompt=body.get("prompt"), model=body.get("model"),
                    worktree=worktree, repo_path=repo_path)
                return _ok({"ok": True, "session": session})

            return _run(_launch)
        return _err(404, "not found")

    # ── /session/<id>[/message|/stop] ──
    if p.startswith("/session/"):
        tail = p[len("/session/"):]
        if not tail:
            return _err(404, "not found")
        parts = tail.split("/")
        sid = parts[0]
        if not sid:
            return _err(404, "not found")
        action = parts[1] if len(parts) > 1 else ""

        # GET /session/<id>
        if action == "" and method == "GET":
            def _get():
                session = manager.status(sid)
                if session is None:
                    return _err(404, "session not found: " + sid)
                return _ok({"ok": True, "session": session,
                            "subagents": manager.subagents(sid)})

            return _run(_get)

        # POST /session/<id>/message
        if action == "message" and method == "POST":
            text = body.get("text")
            if not text:
                return _err(400, "text is required")

            def _msg():
                if manager.status(sid) is None:
                    return _err(404, "session not found: " + sid)
                manager.send_message(sid, text)
                return _ok({"ok": True})

            return _run(_msg)

        # POST /session/<id>/stop
        if action == "stop" and method == "POST":
            def _stop():
                if manager.status(sid) is None:
                    return _err(404, "session not found: " + sid)
                manager.stop(sid)
                return _ok({"ok": True})

            return _run(_stop)

        return _err(404, "not found")

    return _err(404, "not found")
