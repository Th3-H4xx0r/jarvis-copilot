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

_MANAGERS: dict = {}


def default_manager(host: str = "server"):
    """The CodingSessionManager for a given host ('server' or 'desktop').

    Both share the same SQLite store (so list/status see every session), and the
    desktop manager reuses the server manager's config with a DesktopDriver
    swapped in. Lazily built and cached per host.
    """
    host = host if host in ("server", "desktop") else "server"
    if host not in _MANAGERS:
        from tools.coding_session_tool import _mgr

        base = _mgr()  # fully-configured server (LocalDriver) manager
        if host == "server":
            _MANAGERS["server"] = base
        else:
            from agent.coding_host_drivers import DesktopDriver
            from agent.coding_session_manager import CodingSessionManager

            _MANAGERS["desktop"] = CodingSessionManager(
                store=base.store, driver=DesktopDriver(),
                plugin_dir=base.plugin_dir, memory_loader=base.memory_loader,
                long_term_recall=base.long_term_recall,
                context_root=str(base.context_root),
                session_capturer=base.session_capturer)
    return _MANAGERS[host]


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
                          manager, manager_for_host=None) -> tuple[int, dict]:
    """Route a single coding-API request. See module docstring for the contract.

    ``manager`` is the default (server) manager used for most routes. When
    ``manager_for_host`` is provided (the live wiring passes ``default_manager``),
    /launch selects the manager for the requested ``host`` ('server'|'desktop').
    """
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
            # pick the manager for the requested host (server | desktop)
            host = body.get("host") or "server"
            launch_mgr = manager_for_host(host) if manager_for_host else manager

            def _launch():
                session = launch_mgr.launch(
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

        # POST /session/<id>/terminal/start  — attach a live terminal to the
        # session's tmux (server-host sessions only; reuses the existing
        # /api/terminal/{output,input,resize,close} machinery, keyed by <id>).
        if action == "terminal" and len(parts) > 2 and parts[2] == "start" and method == "POST":
            def _term_start():
                session = manager.status(sid)
                if session is None:
                    return _err(404, "session not found: " + sid)
                if (session.get("host") or "server") != "server":
                    return _err(400, "live terminal is only available for server-host sessions")
                tmux_name = session.get("tmux_name")
                if not tmux_name:
                    return _err(409, "session has no tmux session to attach to")
                from api.terminal import start_attach_terminal

                term = start_attach_terminal(
                    sid, tmux_name,
                    rows=int(body.get("rows") or 24),
                    cols=int(body.get("cols") or 80),
                    restart=bool(body.get("restart")))
                return _ok({"ok": True, "session_id": sid, "running": term.is_alive()})

            return _run(_term_start)

        return _err(404, "not found")

    return _err(404, "not found")
