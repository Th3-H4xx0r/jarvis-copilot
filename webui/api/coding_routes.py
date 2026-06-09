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

import logging
import re
from urllib.parse import parse_qs, urlsplit

log = logging.getLogger(__name__)

CODING_PATH_PREFIX = "/api/coding"

_MANAGERS: dict = {}

# Lifecycle statuses for which a live activity_state is meaningful (mirrors
# agent.coding_status_loop / agent.coding_la_push). A stopped/errored row has no
# live pane, so a stray hook for it must NOT revive it.
_LIVE_STATUSES = {"running", "starting", "idle"}

# Claude Code hook event → the live activity_state it announces. A finishing
# Stop means "back at the prompt" (idle); a Notification means "needs you"
# (waiting); a submitted prompt means Claude is now "working". Both snake_case
# and camelCase are tolerated so the hook can pass the raw Claude event name.
_EVENT_STATE = {
    "stop": "idle",
    "notification": "waiting",
    "user_prompt_submit": "working",
    "userpromptsubmit": "working",
}


_PROMPT_OPTION_RE = re.compile(r"^[\s│|]*(?:❯\s*)?(\d+)\.\s+(.*?)[\s│|]*$")
_PROMPT_QUESTION_HINTS = ("do you want", "would you like", "do you trust",
                          "select", "choose", "which", "?")


def _parse_pane_prompt(raw: str):
    """(question, options) parsed from a waiting pane's tail: numbered option
    rows ("❯ 1. Yes" / "│ 2. No │") plus the nearest question-looking line
    above them. Best-effort — callers fall back to the raw tail."""
    options, question = [], None
    lines = (raw or "").splitlines()
    first_opt_idx = None
    for i, line in enumerate(lines):
        m = _PROMPT_OPTION_RE.match(line)
        if m and m.group(2).strip():
            if first_opt_idx is None or not options:
                first_opt_idx = i if first_opt_idx is None else first_opt_idx
            # A new "1." restarts the list (an older menu higher in the tail).
            if m.group(1) == "1" and options:
                options, first_opt_idx = [], i
            options.append({"key": m.group(1),
                            "label": m.group(2).strip()[:120]})
    if options and first_opt_idx is not None:
        for line in reversed(lines[:first_opt_idx]):
            txt = line.strip().strip("│|╭╮╰╯─ ").strip()
            if not txt:
                continue
            low = txt.lower()
            if any(h in low for h in _PROMPT_QUESTION_HINTS):
                question = txt[:200]
                break
            if question is None:
                question = txt[:200]   # fallback: nearest non-empty line
    return question, options


def _match_live_session(store, *, tmux_name="", claude_session_id="", cwd="",
                        device_id=""):
    """Resolve the live coding-session row a hook fired from, or None.

    Match priority, most-specific first:
      1. tmux session name — the hook reads it from its own ``$TMUX_PANE`` and
         it's the session row's join key on BOTH hosts (Jarvis ``jc-xxxx`` or
         a discovered Mac session name). Tried within the sender's device
         scope first, then unscoped: Jarvis-LAUNCHED rows carry no device_id,
         but their ``jc-xxxx`` names are unique, so the exact unscoped match
         is still safe.
      2. claude_session_id — when the hook ran outside tmux.
      3. cwd — exactly ONE live row in scope wins. SEVERAL rows sharing the
         cwd → give up (None): guessing (e.g. most-recently-active) writes the
         event's state onto a sibling session. The poll loops reconcile within
         ~5s, and the notification path doesn't need a row (it labels by cwd).
    When the sender identifies its ``device_id`` (jc-client does), the matches
    are SCOPED to that device's rows: Mac session names are bare numbers
    ("2", "15") and cwds repeat across hosts, so an unscoped match can hit a
    row belonging to a different device/host. That includes the csid pass —
    after a resume-to-server the Mac claude and the server session SHARE one
    csid, and an unscoped csid match would let the still-running Mac twin's
    hooks stamp the server row.
    Never matches a ``discovered-transcript`` row: those are HISTORY entries
    (status "idle" puts them in _LIVE_STATUSES) with no poller that could ever
    clear a state written onto them.
    Only ever matches a *live* row, so a stale hook can't revive a stopped one.
    """
    try:
        rows = store.list_sessions()
    except Exception:
        return None
    live = [r for r in rows
            if r.get("status") in _LIVE_STATUSES
            and r.get("source") != "discovered-transcript"]
    scoped = [r for r in live if r.get("device_id") == device_id] \
        if device_id else live
    if tmux_name:
        for r in scoped:
            if r.get("tmux_name") == tmux_name:
                return r
        # Unscoped fallback ONLY for Jarvis-launched names: launched rows
        # carry no device_id (so the scoped pass misses them) but their
        # ``jc-xxxx`` names are globally unique. Bare user names ("2", "15")
        # stay device-scoped — they repeat across devices.
        if tmux_name.startswith("jc-"):
            for r in live:
                if r.get("tmux_name") == tmux_name:
                    return r
    if claude_session_id:
        for r in scoped:
            if r.get("claude_session_id") == claude_session_id:
                return r
    if cwd:
        hits = [r for r in scoped if r.get("cwd") == cwd]
        if len(hits) == 1:
            return hits[0]
    return None


def _recency_key(row) -> float:
    """Best available recency for a session row (last_activity_at, else updated/created)."""
    for k in ("last_activity_at", "updated_at", "created_at"):
        v = row.get(k)
        try:
            n = float(v)
            return n / 1000.0 if n > 1e12 else n
        except (TypeError, ValueError):
            continue
    return 0.0


def _push_coding_now(store) -> None:
    """Force an immediate APNs Live-Activity push (bypasses the poll tick)."""
    try:
        from agent.coding_la_push import push_coding_update

        push_coding_update(store, usage=_coding_usage(), force=True)
    except Exception:
        pass


def _notify_webui() -> None:
    """Nudge connected browsers (SSE) to refetch now. Never raises."""
    try:
        from api import coding_events

        coding_events.notify()
    except Exception:
        pass


def _folder_label(cwd) -> str:
    return str(cwd or "").rstrip("/").split("/")[-1] or "session"


def _parse_ignore_rules(raw) -> list:
    """Project ``ignore_rules`` is stored as TEXT — accept a JSON list or a
    newline-separated string and normalise to a list of patterns."""
    if not raw:
        return []
    if isinstance(raw, list):
        return [str(x) for x in raw]
    s = str(raw).strip()
    if not s:
        return []
    try:
        import json as _json
        v = _json.loads(s)
        if isinstance(v, list):
            return [str(x) for x in v]
    except Exception:
        pass
    return [ln.strip() for ln in s.splitlines() if ln.strip()]


def _project_sync(proj) -> dict | None:
    """Translate a project's stored sync columns into a session ``sync`` dict (the
    shape manager.launch / start_sync_for_session expect), or None when the
    project's sync is OFF. ``sync_enabled`` is the AUTHORITATIVE switch — a left-
    over device/path (e.g. the user unchecked sync but the device dropdown kept
    its value) must NOT keep sync alive, so we gate solely on ``enabled``."""
    if not isinstance(proj, dict):
        return None
    if not bool(proj.get("sync_enabled")):
        return None
    device = (proj.get("device_id") or "").strip()
    remote = (proj.get("sync_desktop_path") or "").strip()
    return {"enabled": True, "device": device or None,
            "remote_path": remote or None,
            "ignore": _parse_ignore_rules(proj.get("ignore_rules"))}


def _reconcile_project_sync(manager, pid: str, proj) -> None:
    """Apply a project's (now-updated) sync settings to every RUNNING child
    session: persist the project sync dict onto each session and start/stop its
    file sync to match. The project is authoritative — changing it pushes to all
    current children. Scoped to LAUNCHED sessions (a discovered session already
    lives on the device; we don't retro-sync someone's live Mac tmux). Best-
    effort; never raises into the request."""
    try:
        from api.coding_desktop import (start_sync_for_session,
                                        stop_sync_for_session)
    except Exception:
        return
    sync = _project_sync(proj)
    try:
        rows = manager.store.list_sessions(project_id=pid, status="running")
    except Exception:
        rows = []
    import json as _json
    for row in rows:
        sid = row.get("id")
        if not sid or (row.get("source") or "").startswith("discovered"):
            continue
        try:
            if sync:
                manager.store.update_session(sid, sync_config=_json.dumps(sync))
                start_sync_for_session(session_id=sid,
                                       cwd=row.get("cwd") or "", sync=sync)
            else:
                manager.store.update_session(sid, sync_config=None)
                stop_sync_for_session(sid)
        except Exception:  # noqa: BLE001
            continue


def _coding_alert_text(store, row, event) -> tuple[str, str]:
    """(title, body) for a coding-event phone banner — mirrors the wording of
    the Telegram notify.sh hook. Labelled by project name, else the cwd folder."""
    label = ""
    try:
        pid = row.get("project_id")
        if pid and hasattr(store, "get_project"):
            proj = store.get_project(pid) or {}
            label = (proj.get("name") or "").strip()
    except Exception:
        label = ""
    if not label:
        label = _folder_label(row.get("cwd"))
    if event == "stop":
        return ("✅ Claude finished", label)
    return ("🔔 Claude needs you", label)


def _push_device_alert(title: str, body: str) -> int:
    """Send a VISIBLE banner to every registered mobile device, so a coding
    event reaches the phone even when the app is force-quit (unlike the silent
    wake / WS bridge, which iOS won't deliver to a terminated app). Tapping the
    banner relaunches the app — which reconnects the bridge. Best-effort; never
    raises. Returns the number of devices the push reached.
    """
    sent = 0
    try:
        from api.pairing import list_devices
        from api import push as push_mod
    except Exception:
        return 0
    try:
        devices = list_devices()
    except Exception:
        return 0
    for d in devices:
        try:
            token = (d.get("push_token") or "").strip()
            kind = (d.get("push_kind") or "").strip().lower()
            if not token or kind not in ("fcm", "apns"):
                continue
            if not (d.get("kind") or "").strip().lower().startswith("mobile"):
                continue
            res = push_mod.send(kind, token, {"type": "coding"},
                                alert={"title": title, "body": body})
            if res.get("ok"):
                sent += 1
        except Exception:
            continue
    return sent


# ── Code Master notification settings + dispatch ─────────────────────────────
# A coding lifecycle event maps to a settings "event key"; each key carries a
# per-channel on/off matrix. Edited from the WebUI Code Master settings panel
# and stored in the coding DB (coding_settings["notifications"]).
_EVENT_NOTIFY_KEY = {"stop": "finished", "notification": "needs_input",
                     "error": "error"}
_NOTIFY_CHANNELS = ("telegram", "mobile", "toast")
_DEFAULT_NOTIFY_SETTINGS = {
    "events": {
        "finished":    {"telegram": True, "mobile": True, "toast": True},
        "needs_input": {"telegram": True, "mobile": True, "toast": True},
        "error":       {"telegram": True, "mobile": True, "toast": True},
    },
    "usage_display": True,
}


def _merge_notify_settings(stored) -> dict:
    """Overlay stored settings on the defaults so new events/channels added in a
    later release still have a value. Unknown keys in ``stored`` are ignored."""
    out = {
        "events": {k: dict(v) for k, v in _DEFAULT_NOTIFY_SETTINGS["events"].items()},
        "usage_display": _DEFAULT_NOTIFY_SETTINGS["usage_display"],
    }
    if not isinstance(stored, dict):
        return out
    ev = stored.get("events")
    if isinstance(ev, dict):
        for ekey, chans in ev.items():
            if ekey in out["events"] and isinstance(chans, dict):
                for ch in _NOTIFY_CHANNELS:
                    if ch in chans:
                        out["events"][ekey][ch] = bool(chans[ch])
    if "usage_display" in stored:
        out["usage_display"] = bool(stored["usage_display"])
    return out


def _coding_settings(store) -> dict:
    """The effective Code Master settings (defaults overlaid with stored)."""
    stored = None
    try:
        stored = store.get_setting("notifications", None)
    except Exception:
        stored = None
    return _merge_notify_settings(stored)


def _coding_notify_target() -> str:
    """Resolve where a coding notification should go, server-side.

    Order: (1) the cron auto-delivery target when running inside a scheduled job;
    (2) the user's configured messaging home channel — a BARE platform name
    resolves to its home channel in send_message_tool (e.g. "telegram"), which is
    exactly what the old client-side ``jc-client notify`` (``notify_target``)
    did. Returns "" when nothing is configured. Never raises."""
    try:
        from tools.send_message_tool import _get_cron_auto_delivery_target
        t = _get_cron_auto_delivery_target()
        if t:
            ref = f"{t['platform']}:{t['chat_id']}"
            return ref + (f":{t['thread_id']}" if t.get("thread_id") else "")
    except Exception:
        pass
    try:
        from gateway.config import Platform, load_gateway_config
        cfg = load_gateway_config()
        configured = []
        for plat in Platform:
            try:
                if cfg.get_home_channel(plat):
                    configured.append(str(getattr(plat, "value", plat)).lower())
            except Exception:
                continue
        if "telegram" in configured:
            return "telegram"
        if configured:
            return configured[0]
    except Exception:
        pass
    return ""


def _send_coding_telegram(text: str) -> bool:
    """Send a coding notification to the user's messaging channel (Telegram/etc.)
    server-side, the same destination the old notify.sh hook used. Never raises."""
    try:
        import json as _json

        from tools.send_message_tool import send_message_tool
        target = _coding_notify_target()
        if not target:
            return False
        res = _json.loads(send_message_tool(
            {"action": "send", "target": target, "message": text}))
        return bool(res.get("success"))
    except Exception:
        return False


def _dispatch_coding_notifications(store, *, event: str, row, cwd: str = "") -> dict:
    """Fan a coding lifecycle event out to the channels enabled in settings:
    Telegram, mobile push banner, and a WebUI toast. Fires regardless of whether
    the session row was matched (so notifications stay reliable even if the LA
    state-update couldn't bind a row); the label falls back to the cwd folder.
    Returns {channel: bool} for observability. Never raises."""
    ekey = _EVENT_NOTIFY_KEY.get(event)
    if not ekey:
        return {}
    try:
        chans = _coding_settings(store)["events"].get(ekey, {})
    except Exception:
        chans = {}
    title, label = _coding_alert_text(store, row, event) if row is not None else \
        (("✅ Claude finished" if event == "stop" else "🔔 Claude needs you"),
         _folder_label(cwd))
    sent = {}
    # Telegram is sent by the plugin's notify.sh hook (`jc-client notify`, the
    # user's proven messaging path), NOT here — otherwise the user would get TWO
    # Telegram pings per event. This server-side dispatch owns the MOBILE push +
    # WebUI toast (the channels notify.sh can't reach). The telegram channel in the
    # Code Master matrix still governs notify.sh's behavior client-side.
    if chans.get("mobile"):
        try:
            sent["mobile"] = _push_device_alert(title, label) > 0
        except Exception:
            sent["mobile"] = False
    if chans.get("toast"):
        try:
            _notify_webui_event(event=event, label=label, title=title)
            sent["toast"] = True
        except Exception:
            sent["toast"] = False
    return sent


def _notify_webui_event(*, event: str, label: str, title: str) -> None:
    """SSE-push a coding-event payload so open browsers show a toast (and refetch)."""
    try:
        from api import coding_events
        coding_events.notify({"type": "coding-event", "event": event,
                              "label": label, "title": title})
    except Exception:
        pass


def _coding_usage():
    """Best-effort {five_hour_pct, weekly_pct, ...} for the usage rings, or None.
    Non-blocking (reads the cached/persisted snapshot, never hits the network),
    so a usage hiccup can't break or slow the sessions list. Never raises."""
    try:
        from agent.coding_usage import get_usage
        store = None
        try:
            store = default_manager().store  # cold-start fallback: read DB snapshot
        except Exception:
            store = None
        return get_usage(store)
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

        def _sync_stopper(*, session_id):
            # Stop the file sync when a session stops (no-op if a sibling on the
            # same folder pair still runs) so a stopped session can't orphan a sync.
            from api.coding_desktop import stop_sync_for_session

            stop_sync_for_session(session_id)

        # Server-host sessions can sync too (claude on the server, files mirrored
        # to the chosen desktop) — wire the start/stop hooks onto the server manager.
        base.sync_starter = _sync_starter
        base.sync_stopper = _sync_stopper

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
                sync_starter=_sync_starter, sync_stopper=_sync_stopper)
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
                all_projects = manager.store.list_projects()
                active = [p for p in all_projects if not p.get("ignored")]
                ignored = [p for p in all_projects if p.get("ignored")]
                if expand:
                    by_pid = {}
                    for s in manager.list():
                        by_pid.setdefault(s.get("project_id"), []).append(s)
                    for proj in all_projects:
                        proj["sessions"] = by_pid.get(proj["id"], [])
                    # Sessions with no project (legacy rows) surface in a synthetic
                    # bucket so nothing is hidden in the UI. Ignored projects' own
                    # sessions stay attached to them (shown under the Ignored menu).
                    orphans = by_pid.get(None, [])
                    return _ok({"projects": active, "ungrouped": orphans,
                                "ignored": ignored})
                return _ok({"projects": active, "ignored": ignored})

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
                           "sync_desktop_path", "ignore_rules", "device_id",
                           "ignored")
                          if k in body}
                # SAFEGUARD: reject a home/system folder as the sync desktop path
                # so a project can't be configured to sync the whole home dir.
                sdp = (fields.get("sync_desktop_path") or "").strip()
                if sdp:
                    from agent.coding_sync_safety import is_dangerous_path
                    if is_dangerous_path(sdp):
                        return _err(400, f"refusing a home/system sync folder: {sdp!r}")
                sync_changed = any(
                    k in fields for k in ("sync_enabled", "sync_desktop_path",
                                          "ignore_rules", "device_id"))
                manager.store.update_project(pid, **fields)
                proj = manager.store.get_project(pid)
                # Project sync settings are authoritative: a change retro-applies
                # to every running child session (start/stop sync to match).
                if sync_changed:
                    _reconcile_project_sync(manager, pid, proj)
                return _ok({"ok": True, "project": proj})

            return _run(_update_project)

        # DELETE /project/<id>            -> SOFT delete: move to "Ignored" (it stops
        #                                    being re-discovered; Restore brings it
        #                                    + its sessions back).
        # DELETE /project/<id>?permanent=1 -> HARD delete (cascade|detach sessions).
        if paction == "" and method == "DELETE":
            permanent = (query.get("permanent") or "0") == "1"
            cascade = (query.get("delete_sessions") or "0") == "1"

            def _delete_project():
                if manager.store.get_project(pid) is None:
                    return _err(404, "project not found: " + pid)
                if not permanent:
                    # Soft-delete: tombstone the project so discovery can't
                    # resurrect it; keep the row + sessions for Restore.
                    manager.store.update_project(pid, ignored=True)
                    return _ok({"ok": True, "ignored": True})
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
                # The launch form may override sync; otherwise inherit the
                # PROJECT's sync defaults so every child of a synced project syncs.
                sync = body.get("sync")
                if sync is None:
                    sync = _project_sync(proj)
                session = launch_mgr.launch(
                    cwd=cwd, title=body.get("title"),
                    initial_prompt=body.get("prompt"), model=body.get("model"),
                    project_id=pid,
                    skip_permissions=bool(body.get("skip_permissions")),
                    sync=sync,
                    resume_session_id=body.get("resume_session_id"))
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

    # ── /settings ── Code Master notification matrix + usage-display toggle.
    # GET returns the effective settings (defaults overlaid with stored); POST
    # validates against the known events/channels and persists.
    if p == "/settings":
        if method == "GET":
            return _run(lambda: _ok({"settings": _coding_settings(manager.store)}))
        if method == "POST":
            def _save_settings():
                merged = _merge_notify_settings(body if isinstance(body, dict) else {})
                manager.store.set_setting("notifications", merged)
                return _ok({"ok": True, "settings": merged})
            return _run(_save_settings)
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

    # ── /la-debug ── diagnose why the Live Activity isn't push-updating.
    # GET  → {apns_configured, use_sandbox, topic, la_token_count, has_content}.
    # POST → send a RAW test push to each registered token and return the exact
    #        APNs result per token (status/error) WITHOUT deleting any token, so
    #        a sandbox/prod mismatch (HTTP 400 BadDeviceToken) is plainly visible.
    if p == "/la-debug":
        if method == "GET":
            def _la_debug():
                from agent.coding_la_push import build_coding_content_state
                cfg, apns_ok = {}, False
                try:
                    from api.push.apns import _load_config, apns_configured
                    cfg = _load_config() or {}
                    apns_ok = apns_configured()
                except Exception:
                    pass
                try:
                    tokens = manager.store.list_la_tokens()
                except Exception:
                    tokens = []
                cs = build_coding_content_state(manager.store, _coding_usage())
                return _ok({
                    "apns_configured": apns_ok,
                    "use_sandbox": bool(cfg.get("use_sandbox")),
                    "apns_topic": cfg.get("topic"),
                    "la_token_count": len(tokens),
                    "la_token_tails": [str(t.get("token"))[-6:] for t in tokens],
                    "has_content_state": cs is not None,
                    "content_state": cs,
                })
            return _run(_la_debug)
        if method == "POST":
            def _la_debug_push():
                from agent.coding_la_push import build_coding_content_state
                from api.push.apns import send_live_activity
                try:
                    tokens = manager.store.list_la_tokens()
                except Exception:
                    tokens = []
                cs = build_coding_content_state(manager.store, _coding_usage()) or {
                    "state": "idle", "transcript": "", "activity": "",
                    "connected": True, "devices": [], "mode": "coding",
                    "sessions": [], "sessionTotal": 0, "entryTotal": 0,
                    "waitingCount": 0, "usage5": -1, "usageWeek": -1,
                    "usage5Resets": "", "usageWeekResets": "",
                }
                results = []
                for t in tokens:
                    tok = t.get("token")
                    if not tok:
                        continue
                    res = send_live_activity(tok, cs, event="update")
                    results.append({"token_tail": str(tok)[-6:], **res})
                return _ok({"token_count": len(tokens),
                            "pushed": sum(1 for r in results if r.get("ok")),
                            "results": results})
            return _run(_la_debug_push)
        return _err(404, "not found")

    # ── /test-alert ── send a VISIBLE banner to every registered mobile device,
    # to verify the notification path (reaches a force-quit phone, unlike the
    # silent LA push). Reports the per-device APNs result so a MISSING device
    # notification token (separate from the LA token) is plainly visible.
    if p == "/test-alert":
        if method == "POST":
            def _test_alert():
                from api.pairing import list_devices
                from api import push as push_mod
                try:
                    devices = list_devices()
                except Exception:
                    devices = []
                mobile = [d for d in devices
                          if (d.get("kind") or "").lower().startswith("mobile")]
                results = []
                for d in mobile:
                    name = d.get("name") or d.get("id") or "device"
                    token = (d.get("push_token") or "").strip()
                    kind = (d.get("push_kind") or "").strip().lower()
                    if not token or kind not in ("fcm", "apns"):
                        results.append({"device": name, "ok": False,
                                        "error": "no notification token registered"})
                        continue
                    res = push_mod.send(
                        kind, token, {"type": "coding", "test": True},
                        alert={"title": "JarvisCopilot",
                               "body": "🔔 Test notification — reachable when closed"})
                    results.append({"device": name, "kind": kind, **res})
                return _ok({"mobile_devices": len(mobile),
                            "sent": sum(1 for r in results if r.get("ok")),
                            "results": results})
            return _run(_test_alert)
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
                    project_id=body.get("project_id"),
                    skip_permissions=bool(body.get("skip_permissions")),
                    sync=body.get("sync"),
                    resume_session_id=body.get("resume_session_id"))
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
                    clear_dismissed, get_desktop_bridge, resolve_desktop_device_id)

                device_id = resolve_desktop_device_id()
                if not device_id:
                    return _ok({"ok": False})
                # Rescan is the recovery path: clear tombstones so sessions hidden
                # by a Stop / Resume re-appear when the user explicitly re-scans.
                clear_dismissed(device_id)
                get_desktop_bridge().send_discover_request(device_id)
                return _ok({"ok": True, "device": device_id})

            return _run(_discover_refresh)
        return _err(404, "not found")

    # ── /activity-event ── INSTANT, hook-driven activity_state update.
    # A Claude Code Stop/Notification/UserPromptSubmit hook (via `jc-client
    # coding-event`) reports the live transition the moment it happens, so the
    # iOS Live Activity (force APNs push) and the WebUI (SSE) update INSTANTLY
    # instead of waiting for the 4-5s poll loops to rediscover it. The poll
    # loops stay as the reconciling backstop (and cover any session whose hooks
    # don't fire). Reaches this same endpoint from BOTH hosts: a server-host
    # hook POSTs to localhost; a Mac-host hook POSTs over the jc-client tunnel.
    if p == "/activity-event":
        if method != "POST":
            return _err(404, "not found")
        event = (body.get("event") or "").strip().lower()
        state = _EVENT_STATE.get(event)
        if state is None:
            return _err(400, "unknown event: " + (event or "(empty)"))
        tmux_name = (body.get("tmux_name") or "").strip()
        csid = (body.get("claude_session_id") or "").strip()
        cwd = (body.get("cwd") or "").strip()
        device_id = (body.get("device_id") or "").strip()

        def _activity_event():
            row = _match_live_session(
                manager.store, tmux_name=tmux_name,
                claude_session_id=csid, cwd=cwd, device_id=device_id)
            matched = row is not None
            changed = False
            if matched:
                changed = row.get("activity_state") != state
                if changed:
                    manager.store.update_session(row["id"], activity_state=state)
                    # Fan the new state out INSTANTLY: LA force-push + WebUI SSE.
                    # Only on a real transition, so a repeated hook costs nothing.
                    _push_coding_now(manager.store)
                    _notify_webui()
            # Notifications for the edges the user must see (finished/needs-input),
            # gated by the Code Master settings matrix (Telegram + mobile + toast).
            # Fire even when the row couldn't be matched so they stay reliable.
            sent = {}
            if event in ("stop", "notification"):
                sent = _dispatch_coding_notifications(
                    manager.store, event=event, row=row, cwd=cwd)
            # Diagnosis breadcrumb: confirms the instant path matched + pushed,
            # vs falling back to the reconcile poll (the old lag cause).
            log.info("coding activity-event: event=%s state=%s matched=%s "
                     "changed=%s notified=%s", event, state, matched, changed, sent)
            return _ok({"ok": True, "matched": matched,
                        "session_id": row["id"] if row else None,
                        "state": state, "changed": changed, "notified": sent})

        return _run(_activity_event)

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

        # GET /session/<id>/messages?after=N — the chat-view message list,
        # parsed from the session's Claude Code transcript (the canonical
        # record of every message; the Stop/UserPromptSubmit hooks bump
        # last_activity so pollers know when to re-read). Desktop sessions
        # pull the transcript over the device bridge and cache the parsed
        # list in the DB so history survives the Mac going offline.
        if action == "messages" and method == "GET":
            try:
                after = max(0, int(query.get("after") or 0))
            except (TypeError, ValueError):
                after = 0

            def _messages():
                import time as _time

                from agent.coding_transcript_read import (
                    parse_transcript_text, read_local_messages, slice_messages)

                row = manager.status(sid)
                if row is None:
                    return _err(404, "session not found: " + sid)
                csid = (row.get("claude_session_id") or "").strip()
                cwd = row.get("cwd") or ""
                if not csid:
                    return _err(409, "no transcript yet for this session")
                host = (row.get("host") or "server")
                msgs, source = None, "live"
                if host == "desktop" and (row.get("device_id") or ""):
                    cache = manager.store.get_transcript_cache(csid)
                    last_act = float(row.get("last_activity_at") or 0)
                    cache_ts = float(cache["updated_at"]) if cache else 0.0
                    # Re-pull when the cache is missing, predates the latest
                    # activity, or is simply old while the session is live —
                    # otherwise serve the cache (mobile polls every ~3s; the
                    # bridge pull is the expensive path).
                    stale = (cache is None or last_act > cache_ts
                             or _time.time() - cache_ts > 8)
                    if stale:
                        try:
                            from api.coding_desktop import get_desktop_bridge
                            raw = get_desktop_bridge().request_transcript(
                                row.get("device_id"), claude_session_id=csid,
                                cwd=cwd, timeout=20)
                        except Exception:  # noqa: BLE001
                            raw = None
                        if raw:
                            msgs = parse_transcript_text(
                                raw.decode("utf-8", errors="replace"))
                            manager.store.set_transcript_cache(csid, msgs)
                    if msgs is None and cache is not None:
                        msgs, source = cache["messages"], "cache"
                if msgs is None:
                    msgs, _mt = read_local_messages(cwd, csid)
                if msgs is None:
                    return _err(409, "transcript not available")
                payload = slice_messages(msgs, after)
                payload.update(ok=True, source=source,
                               activity_state=row.get("activity_state"),
                               status=row.get("status"))
                return _ok(payload)

            return _run(_messages)

        # GET /session/<id>/prompt — when the session is WAITING, the live
        # pane's prompt parsed into {question, options:[{key,label}]} so the
        # mobile chat view can answer with a tap instead of the raw terminal.
        if action == "prompt" and method == "GET":
            def _prompt():
                row = manager.status(sid)
                if row is None:
                    return _err(404, "session not found: " + sid)
                waiting = (row.get("activity_state") or "") == "waiting"
                raw = None
                if waiting:
                    host = (row.get("host") or "server")
                    tn = (row.get("tmux_name") or "").strip()
                    if host == "server" and tn:
                        try:
                            raw = manager.driver.capture_pane(
                                tmux_name=tn, lines=40)
                        except Exception:  # noqa: BLE001
                            raw = None
                    else:
                        try:
                            from api.coding_desktop import get_waiting_tail
                            raw = get_waiting_tail(row)
                        except Exception:  # noqa: BLE001
                            raw = None
                q, opts = _parse_pane_prompt(raw) if raw else (None, [])
                return _ok({"ok": True, "waiting": waiting, "question": q,
                            "options": opts,
                            "raw": (raw[-1500:] if raw else None)})

            return _run(_prompt)

        # POST /session/<id>/stop
        if action == "stop" and method == "POST":
            def _stop():
                row = manager.status(sid)
                if row is None:
                    return _err(404, "session not found: " + sid)
                manager.stop(sid)
                # A DISCOVERED session is a live Mac tmux the server can't kill, so
                # without a tombstone the next 5s discovery push flips it right back
                # to running — the stopped<->running flip-flop that churns the UI.
                # Tombstone it so Stop sticks (Rescan brings it back).
                if (row.get("source") or "").startswith("discovered"):
                    try:
                        from api.coding_desktop import dismiss_discovered
                        dev = (row.get("device_id") or "").strip()
                        tn = (row.get("tmux_name") or "").strip()
                        csid = (row.get("claude_session_id") or "").strip()
                        for ident in (tn, csid):
                            if dev and ident:
                                dismiss_discovered(dev, ident)
                    except Exception:
                        pass
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
                            # resume-to-server when the Mac is offline. Resume
                            # needs a csid (`claude --resume <id>`); rows in a
                            # cwd with several live siblings are left bare on
                            # purpose, so don't offer a button that would 400.
                            can = bool(session.get("claude_session_id"))
                            return 409, {"error": "desktop is offline",
                                         "can_resume": can}
                        return _ok({"ok": True, "session_id": sid,
                                    "running": res.get("running", True)})
                    # A Jarvis-LAUNCHED desktop session already runs tmux+claude
                    # and streams coding_term_output; just attach a feed. fresh=True
                    # drops a stale CLOSED feed left by a prior WS drop so a reopen
                    # after the Mac reconnects re-wires cleanly (the manager-owned
                    # tmux+claude keep streaming) instead of returning the dead feed.
                    device_id = resolve_desktop_device_id()
                    if not device_id:
                        return _err(409, "desktop client is not connected")
                    feed = get_desktop_bridge().attach_feed(
                        session_id=sid, device_id=device_id, term_id=tmux_name,
                        rows=rows, cols=cols, fresh=True)
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
