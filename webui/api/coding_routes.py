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
    GET  /sessions [?status=]            -> 200 {"sessions": [...],
                                                 "usage": {...}|None}
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


def _coding_usage():
    """Best-effort {five_hour_pct, weekly_pct, ...} for the usage rings, or None.
    Never raises (so a usage hiccup can't break the sessions list)."""
    try:
        from agent.coding_usage import get_usage
        return get_usage()
    except Exception:
        return None


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

        def _sync_starter(*, session_id, cwd, sync):
            # Kick the file sync for a session that opted in, on EITHER host.
            from api.coding_desktop import start_sync_for_session

            start_sync_for_session(session_id=session_id, cwd=cwd, sync=sync)

        # Server-host sessions can sync too (claude on the server, files mirrored
        # to the chosen desktop) — wire the starter onto the server manager.
        base.sync_starter = _sync_starter

        if host == "server":
            _MANAGERS["server"] = base
        else:
            from agent.coding_host_drivers import DesktopDriver
            from agent.coding_session_manager import CodingSessionManager

            def _desktop_bridge_run_factory():
                # Resolve the connected desktop client + an in-process bridge_run
                # at launch time, so the cached manager binds to whichever client
                # is connected now (devices come and go).
                from api.coding_desktop import (
                    make_bridge_run, resolve_desktop_device_id)

                device_id = resolve_desktop_device_id()
                if not device_id:
                    return None
                return make_bridge_run(device_id)

            # Sync is kicked by the manager's sync_starter for ALL hosts now,
            # so the desktop driver no longer kicks it via on_launched (avoids a
            # double-sync). on_launched_fn stays None.
            _MANAGERS["desktop"] = CodingSessionManager(
                store=base.store,
                driver=DesktopDriver(
                    bridge_run_factory=_desktop_bridge_run_factory),
                plugin_dir=base.plugin_dir, memory_loader=base.memory_loader,
                long_term_recall=base.long_term_recall,
                context_root=str(base.context_root),
                session_capturer=base.session_capturer,
                sync_starter=_sync_starter)
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
            expand = (query.get("expand") or "") == "sessions"

            def _list_projects():
                projects = manager.store.list_projects()
                if expand:
                    by_pid = {}
                    for s in manager.list():
                        by_pid.setdefault(s.get("project_id"), []).append(s)
                    for proj in projects:
                        proj["sessions"] = by_pid.get(proj["id"], [])
                    # Sessions with no project (legacy rows) surface in a synthetic
                    # bucket so nothing is hidden in the UI.
                    orphans = by_pid.get(None, [])
                    return _ok({"projects": projects,
                                "ungrouped": orphans})
                return _ok({"projects": projects})

            return _run(_list_projects)
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

    # ── /project/<id>[/session] ──
    if p.startswith("/project/"):
        ptail = p[len("/project/"):]
        pparts = ptail.split("/")
        pid = pparts[0]
        paction = pparts[1] if len(pparts) > 1 else ""
        if not pid:
            return _err(404, "not found")

        # POST /project/<id>  — rename / set sync / default_branch
        if paction == "" and method == "POST":
            def _update_project():
                if manager.store.get_project(pid) is None:
                    return _err(404, "project not found: " + pid)
                fields = {k: body[k] for k in
                          ("name", "default_branch", "sync_enabled",
                           "sync_desktop_path", "ignore_rules", "device_id")
                          if k in body}
                manager.store.update_project(pid, **fields)
                return _ok({"ok": True, "project": manager.store.get_project(pid)})

            return _run(_update_project)

        # DELETE /project/<id>?delete_sessions=0|1
        if paction == "" and method == "DELETE":
            cascade = (query.get("delete_sessions") or "0") == "1"

            def _delete_project():
                if manager.store.get_project(pid) is None:
                    return _err(404, "project not found: " + pid)
                for s in manager.store.list_sessions(project_id=pid):
                    if cascade:
                        try:
                            manager.delete(s["id"])
                        except Exception:
                            pass
                    else:
                        manager.store.update_session(s["id"], project_id=None)
                manager.store.delete_project(pid)
                return _ok({"ok": True})

            return _run(_delete_project)

        # POST /project/<id>/session  — launch a session IN this project
        if paction == "session" and method == "POST":
            def _launch_in_project():
                proj = manager.store.get_project(pid)
                if proj is None:
                    return _err(404, "project not found: " + pid)
                host = body.get("host") or proj.get("host") or "server"
                launch_mgr = manager_for_host(host) if manager_for_host else manager
                cwd = body.get("cwd") or proj.get("repo_path")
                session = launch_mgr.launch(
                    cwd=cwd, title=body.get("title"),
                    initial_prompt=body.get("prompt"), model=body.get("model"),
                    project_id=pid,
                    skip_permissions=bool(body.get("skip_permissions")),
                    sync=body.get("sync"))
                return _ok({"ok": True, "session": session})

            return _run(_launch_in_project)

        return _err(404, "not found")

    # ── /sessions ──
    if p == "/sessions":
        if method == "GET":
            status = query.get("status") or None
            return _run(lambda: _ok({"sessions": manager.list(status=status),
                                     "usage": _coding_usage()}))
        return _err(404, "not found")

    # ── /usage ── (just the account usage block, for the Live Activity rings)
    if p == "/usage":
        if method == "GET":
            return _run(lambda: _ok({"usage": _coding_usage()}))
        return _err(404, "not found")

    # ── /la-token ── register the iOS Live Activity push token (for APNs
    # push-to-update, so the activity stays live while the app is suspended).
    if p == "/la-token":
        if method == "POST":
            token = ((body or {}).get("token") or "").strip()
            device_id = ((body or {}).get("device_id") or "").strip()
            if not token:
                return _err(400, "token required")

            def _store():
                manager.store.upsert_la_token(token, device_id or None)
                return _ok({"ok": True})
            return _run(_store)
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
                    worktree=worktree, repo_path=repo_path,
                    skip_permissions=bool(body.get("skip_permissions")),
                    sync=body.get("sync"))
                return _ok({"ok": True, "session": session})

            return _run(_launch)
        return _err(404, "not found")

    # ── /discover/refresh ──
    # Ask the connected desktop client to (re)scan its live claude tmux sessions
    # and push a coding_discover frame now; the server ingests it asynchronously
    # (see api.coding_desktop.ingest_discovered). No body required.
    if p == "/discover/refresh":
        if method == "POST":
            def _discover_refresh():
                from api.coding_desktop import (
                    get_desktop_bridge, resolve_desktop_device_id)

                device_id = resolve_desktop_device_id()
                if not device_id:
                    return _ok({"ok": False})
                get_desktop_bridge().send_discover_request(device_id)
                return _ok({"ok": True, "device": device_id})

            return _run(_discover_refresh)
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
                # Sync the (now-final) transcript OUT to the device so a later
                # local `claude --resume` on the Mac sees this session's turns.
                # Fire-and-forget (off the request thread): nothing here depends
                # on it, and a 30s device round-trip on the request thread holds
                # an edge connection slot and can 503 other requests under load.
                try:
                    from api.coding_desktop import reconcile_session_transcript_async
                    reconcile_session_transcript_async(sid)
                except Exception:
                    pass
                return _ok({"ok": True})

            return _run(_stop)

        # POST /session/<id>/restart  — resume the conversation (claude --continue)
        if action == "restart" and method == "POST":
            def _restart():
                if manager.status(sid) is None:
                    return _err(404, "session not found: " + sid)
                # Pull the device's latest transcript IN first (newest-wins), so
                # `claude --continue` picks up changes made on the Mac since this
                # server session last ran. One-shot, BEFORE claude starts.
                try:
                    from api.coding_desktop import reconcile_session_transcript
                    reconcile_session_transcript(sid)
                except Exception:
                    pass
                session = manager.restart(sid)
                return _ok({"ok": True, "session": session})

            return _run(_restart)

        # POST /session/<id>/resume  — resume a DISCOVERED (Mac) session as a new
        # session ON THE SERVER: pull its transcript from the device, mirror it
        # into the server's ~/.claude, and run `claude --resume <csid>` in a
        # server-side checkout with sync back to the Mac. The discovered session
        # NEVER relaunches on the Mac.
        if action == "resume" and method == "POST":
            def _resume():
                row = manager.status(sid)
                if row is None:
                    return _err(404, "session not found: " + sid)
                # Resume is ONLY for discovered (device-side) rows. A server-host
                # / Jarvis-launched session that happens to carry a
                # claude_session_id must be rejected — it already runs on the
                # server; "resuming" it would spin up a confusing duplicate.
                if not (row.get("source") or "").startswith("discovered"):
                    return _err(400, "only discovered sessions can be resumed")
                if not (row.get("claude_session_id") or "").strip():
                    return _err(400, "session has no claude_session_id to resume")
                from api.coding_desktop import (
                    get_desktop_bridge, resolve_desktop_device_id,
                    resume_discovered_to_server)

                device_id = (row.get("device_id") or "").strip() \
                    or resolve_desktop_device_id()
                if not device_id:
                    return _err(409, "desktop client is not connected")
                # Always run the resumed session on the SERVER (host LocalDriver),
                # regardless of where the discovered session was scanned.
                server_mgr = (manager_for_host("server")
                              if manager_for_host else manager)
                result = resume_discovered_to_server(
                    sid, manager=server_mgr, bridge=get_desktop_bridge())
                payload = {"ok": True, "session": result.get("session")}
                if result.get("warning"):
                    payload["warning"] = result["warning"]
                return _ok(payload)

            return _run(_resume)

        # POST or DELETE /session/<id>/delete  — stop + permanently remove
        if action == "delete" and method in ("POST", "DELETE"):
            def _delete():
                if manager.status(sid) is None:
                    return _err(404, "session not found: " + sid)
                # Stop the file sync first so the desktop terminates its Mutagen
                # session + poller (otherwise it lingers as a stale "active"
                # sync in the tray until the next reconnect-reconcile).
                try:
                    from api.coding_desktop import stop_sync_for_session
                    stop_sync_for_session(sid)
                except Exception:
                    pass
                manager.delete(sid)
                return _ok({"ok": True})

            return _run(_delete)

        # GET /session/<id>/sync  — sync status (device, online, progress)
        if action == "sync" and len(parts) <= 2 and method == "GET":
            def _sync_get():
                row = manager.status(sid)
                if row is None:
                    return _err(404, "session not found: " + sid)
                from api.coding_desktop import sync_status

                return _ok(sync_status(sid, row.get("sync_config"), cwd=row.get("cwd")))

            return _run(_sync_get)

        # POST /session/<id>/sync/refresh  — re-open the sync (re-reconcile)
        if (action == "sync" and len(parts) > 2 and parts[2] == "refresh"
                and method == "POST"):
            def _sync_refresh():
                row = manager.status(sid)
                if row is None:
                    return _err(404, "session not found: " + sid)
                import json as _json
                from api.coding_desktop import start_sync_for_session

                cfg = None
                if row.get("sync_config"):
                    try:
                        cfg = _json.loads(row["sync_config"])
                    except Exception:
                        cfg = None
                start_sync_for_session(session_id=sid, cwd=row.get("cwd"), sync=cfg)
                from api.coding_desktop import sync_status

                return _ok(sync_status(sid, row.get("sync_config"), cwd=row.get("cwd")))

            return _run(_sync_refresh)

        # POST /session/<id>/settings  — update stored settings (skip-perms,
        # sync, cwd, title). cwd/skip-perms apply on next Restart.
        if action == "settings" and method == "POST":
            def _settings():
                if manager.status(sid) is None:
                    return _err(404, "session not found: " + sid)
                session = manager.update_settings(
                    sid,
                    skip_permissions=body.get("skip_permissions"),
                    sync=body.get("sync"),
                    cwd=body.get("cwd"),
                    title=body.get("title"))
                return _ok({"ok": True, "session": session})

            return _run(_settings)

        # POST /session/<id>/terminal/start  — attach a live terminal to the
        # session's tmux (server-host sessions only; reuses the existing
        # /api/terminal/{output,input,resize,close} machinery, keyed by <id>).
        if action == "terminal" and len(parts) > 2 and parts[2] == "start" and method == "POST":
            def _term_start():
                session = manager.status(sid)
                if session is None:
                    return _err(404, "session not found: " + sid)
                host = session.get("host") or "server"
                tmux_name = session.get("tmux_name")
                if not tmux_name:
                    return _err(409, "session has no tmux session to attach to")
                rows = int(body.get("rows") or 24)
                cols = int(body.get("cols") or 80)
                if host == "desktop":
                    from api.coding_desktop import (
                        adopt_discovered_tmux, get_desktop_bridge,
                        resolve_desktop_device_id)

                    # A DISCOVERED live Mac tmux session: ADOPT it — tell the
                    # desktop to open a PTY attached to the user's existing tmux,
                    # so web/phone drive the SAME live claude (one process, no
                    # fork). If the Mac is offline, signal the front-end to offer
                    # resume-to-server instead.
                    if (session.get("source") or "").startswith("discovered"):
                        res = adopt_discovered_tmux(sid, rows=rows, cols=cols)
                        if not res.get("ok"):
                            # 409 + can_resume so the front-end offers
                            # resume-to-server when the Mac is offline.
                            return 409, {"error": "desktop is offline",
                                         "can_resume": True}
                        return _ok({"ok": True, "session_id": sid,
                                    "running": res.get("running", True)})
                    # A Jarvis-LAUNCHED desktop session already runs tmux+claude
                    # and streams coding_term_output; just attach a feed.
                    device_id = resolve_desktop_device_id()
                    if not device_id:
                        return _err(409, "desktop client is not connected")
                    feed = get_desktop_bridge().attach_feed(
                        session_id=sid, device_id=device_id, term_id=tmux_name,
                        rows=rows, cols=cols)
                    return _ok({"ok": True, "session_id": sid,
                                "running": feed.is_alive()})
                if host != "server":
                    return _err(400, "live terminal is not available for this session host")
                from api.terminal import start_attach_terminal

                term = start_attach_terminal(
                    sid, tmux_name, rows=rows, cols=cols,
                    restart=bool(body.get("restart")))
                return _ok({"ok": True, "session_id": sid, "running": term.is_alive()})

            return _run(_term_start)

        return _err(404, "not found")

    return _err(404, "not found")
