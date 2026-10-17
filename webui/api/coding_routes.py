"""Pure HTTP dispatcher for JarvisCopilot's coding API (``/api/coding/*``).

The single public entry point, :func:`handle_coding_request`, takes the method,
the path (already stripped to the part after ``/api/coding``), the parsed JSON
body and the shared store holder (``default_manager()``; tests pass a fake with a
``.store``), and returns ``(status_code, payload_dict)``. The wiring in
``routes.py`` adapts that tuple to the wire.

Sessions themselves live in the Agents layer (``/agents/*``, mounted from
``agents_routes.py``): one record per conversation, driven by hooks. What stays
here is around them::

    GET  /projects[?expand=sessions[&live=1]] -> {projects, ungrouped?, ignored?}
    POST /projects {name, repo_path}          -> {ok, project_id}
    POST /project/<id> {name?, sync_enabled?, sync_desktop_path?, ignore_rules?,
                        device_id?, ignored?}  -> {ok, project}
    DELETE /project/<id>[?permanent=1]        -> {ok}
    GET  /usage, /dir-suggest, /settings, /la-debug, /agent-la/state
    POST /settings, /la-token, /agent-la/token, /test-alert, /la-debug
    /permission/{request,poll,verdict,pending}

Errors: 400 on validation, 404 on an unknown route or id, 500 on anything else
(with ``{"error": str(e)}``).
"""
from __future__ import annotations

import logging
import threading
from urllib.parse import parse_qs, urlsplit

log = logging.getLogger(__name__)

CODING_PATH_PREFIX = "/api/coding"

def _push_coding_now(store) -> None:
    """Push the latest APNs Live-Activity state now (don't wait for the poll
    tick). NOT forced — goes through the dedupe + rate-limit so a flapping fleet
    can't fire a priority push on every working↔waiting↔idle transition."""
    try:
        from agent.coding_la_push import push_coding_update

        push_coding_update(store, usage=_coding_usage(), force=False)
    except Exception:
        pass


def _notify_webui() -> None:
    """Nudge connected browsers (SSE) to refetch now. Never raises."""
    try:
        from api import coding_events

        coding_events.notify()
    except Exception:
        pass


def _agent_la_pusher(store):
    """The process pusher (agent_hooks.start sets it), else a stateless one over
    this store — enough to answer /agent-la/state before the tracker runs."""
    from agent import agent_la_push
    p = agent_la_push.pusher()
    if p is not None:
        return p
    return agent_la_push.AgentLaPusher(
        store, settings=lambda: _coding_settings(store).get("agent_live"))


def _tick_agent_las_soon() -> None:
    """Re-apply the per-agent activities off the request thread (APNs is network),
    on the same single ticker the hooks use, so ticks never run side by side."""
    try:
        from api import agent_hooks
        agent_hooks._agent_la_tick()
    except Exception:  # noqa: BLE001
        pass


def _agent_la_token(store, body: dict):
    from agent import agent_la_push
    kind = str(body.get("kind") or "").strip()
    token = str(body.get("token") or "").strip()
    device = str(body.get("device_id") or "").strip() or "unknown"
    ended = bool(body.get("ended"))
    p = _agent_la_pusher(store)
    if kind == "start":
        p.register_start_token(device, token)
        _tick_agent_las_soon()   # an agent already live gets its activity now
        return _ok({"ok": True})
    if kind == "device":
        if ended:
            p.forget_device(device)
        return _ok({"ok": True})
    if kind == "activity":
        agent = str(body.get("agent") or "").strip()
        if agent_la_push.group_of(agent) is None:
            return _err(400, "unknown agent")
        if ended:
            p.activity_ended(device, agent, token, dismissed=bool(body.get("dismissed")))
            return _ok({"ok": True})
        if not token:
            return _err(400, "token required")
        p.register_activity_token(device, agent, token)
        return _ok({"ok": True})
    return _err(400, "kind must be start, activity or device")


def _folder_label(cwd) -> str:
    return str(cwd or "").rstrip("/").split("/")[-1] or "session"


_AGENT_WORD = {"codex": "Codex", "gemini": "Gemini", "cursor": "Cursor", "copilot": "Copilot",
               "opencode": "OpenCode", "amp": "Amp", "antigravity": "Antigravity", "muse": "Muse"}


def _coding_alert_text(store, row, event) -> tuple[str, str]:
    """(title, body) for a coding-event phone banner. ``row`` is the session as the
    hook tracker describes it (agent, cwd, project, project_id, title). Labelled by
    the project's name, else the session's project, else the cwd folder."""
    label = ""
    try:
        pid = row.get("project_id")
        if pid and hasattr(store, "get_project"):
            proj = store.get_project(pid) or {}
            label = (proj.get("name") or "").strip()
    except Exception:
        label = ""
    if not label:
        label = str(row.get("project") or "").strip() or _folder_label(row.get("cwd"))
    who = _AGENT_WORD.get(str(row.get("agent") or "").lower(), "Claude")
    if event == "stop":
        return (f"✅ {who} finished", label)
    return (f"🔔 {who} needs you", label)


# Per-(session,event) debounce for the mobile banner — a flapping edge must not
# wake every phone with a banner every few seconds.
_last_alert: dict = {}
_ALERT_DEBOUNCE = 5.0  # seconds — catches few-second flapping, lets distinct prompts through


def _push_device_alert(title: str, body: str, data: dict | None = None, wake: bool = False) -> int:
    """Send a VISIBLE banner to every registered mobile device, so a coding
    event reaches the phone even when the app is force-quit (unlike the silent
    wake / WS bridge, which iOS won't deliver to a terminated app). Tapping the
    banner relaunches the app — which reconnects the bridge. ``wake``: it also
    wakes the app (it carries a glasses card). Best-effort; never raises.
    Returns the number of devices the push reached.
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
            if not token or kind != "apns":
                continue
            if not (d.get("kind") or "").strip().lower().startswith("mobile"):
                continue
            res = push_mod.send(kind, token, data or {"type": "coding"},
                                alert={"title": title, "body": body, **({"wake": True} if wake else {})})
            if res.get("ok"):
                sent += 1
        except Exception:
            continue
    return sent


def _permission_summary(tool: str, tinput) -> str:
    """One-line human summary of a tool the agent wants to run, e.g.
    'Bash: rm -rf build/' or 'Write: src/app.py'."""
    tool = str(tool or "tool")
    if not isinstance(tinput, dict):
        return tool
    for key in ("command", "file_path", "path", "url", "pattern", "query",
                "description", "prompt"):
        v = tinput.get(key)
        if isinstance(v, str) and v.strip():
            line = v.strip().splitlines()[0]
            return f"{tool}: {line[:140]}"
    return tool


def _push_permission_alert(*, title: str, body: str, data: dict) -> int:
    """Send an ACTIONABLE permission banner (category PERMISSION_APPROVAL, with
    Approve/Deny/Reply actions) to every registered mobile device, carrying the
    request_id + session in the data envelope. Returns how many it reached."""
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
            if not token or kind != "apns":
                continue
            if not (d.get("kind") or "").strip().lower().startswith("mobile"):
                continue
            res = push_mod.send(kind, token, data, alert={
                "title": title, "body": body,
                "category": "PERMISSION_APPROVAL"})
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
_STATIC_NOTIFY_CHANNELS = [
    {"key": "telegram", "label": "Telegram", "icon": "paperplane.fill", "default_on": True},
    {"key": "mobile",   "label": "Mobile push", "icon": "iphone", "default_on": True},
    {"key": "toast",    "label": "WebUI toast", "icon": "bell.badge", "default_on": True},
    {"key": "photon",   "label": "iMessage", "icon": "message", "default_on": False},
]

def _available_notify_channels() -> list[dict]:
    """Static channels + any device-registered notification channels."""
    out = list(_STATIC_NOTIFY_CHANNELS)
    seen = {c["key"] for c in out}
    try:
        from api.device_bridge import all_device_notification_channels
        for ch in all_device_notification_channels():
            if ch["key"] not in seen:
                seen.add(ch["key"])
                out.append(ch)
    except Exception:
        pass
    return out

_DEFAULT_NOTIFY_SETTINGS = {
    "events": {
        "finished":    {"telegram": True, "mobile": True, "toast": True, "photon": False},
        "needs_input": {"telegram": True, "mobile": True, "toast": True, "photon": False},
        "error":       {"telegram": True, "mobile": True, "toast": True, "photon": False},
    },
    "usage_display": True,
    "remote_approvals": False,
    # Let the phone send messages into a Mac session (typed into its terminal
    # or handed over at its next Stop). Off unless turned on.
    "remote_instructions": False,
    # Per-agent Live Activities on the iPhone (agent/agent_la_push.py): on/off,
    # which agents, end-after-idle minutes, Allow / Deny on the Lock Screen.
    # Defaults and validation live in agent_la_push.merge_settings.
}


def _merge_notify_settings(stored) -> dict:
    """Overlay stored settings on the defaults so new events/channels added in a
    later release still have a value. Dynamic device channels get their own
    default_on from the registration. Unknown keys in ``stored`` are ignored."""
    from agent.agent_la_push import merge_settings as _merge_agent_live
    all_channels = _available_notify_channels()
    all_keys = {c["key"] for c in all_channels}
    default_row = {c["key"]: c.get("default_on", False) for c in all_channels}
    out = {
        "events": {k: {**default_row, **{ck: cv for ck, cv in v.items() if ck in all_keys}}
                   for k, v in _DEFAULT_NOTIFY_SETTINGS["events"].items()},
        "usage_display": _DEFAULT_NOTIFY_SETTINGS["usage_display"],
        "remote_approvals": _DEFAULT_NOTIFY_SETTINGS["remote_approvals"],
        "remote_instructions": _DEFAULT_NOTIFY_SETTINGS["remote_instructions"],
        "agent_live": _merge_agent_live(None),
    }
    if not isinstance(stored, dict):
        return out
    ev = stored.get("events")
    if isinstance(ev, dict):
        for ekey, chans in ev.items():
            if ekey in out["events"] and isinstance(chans, dict):
                for ch in all_keys:
                    if ch in chans:
                        out["events"][ekey][ch] = bool(chans[ch])
    if "usage_display" in stored:
        out["usage_display"] = bool(stored["usage_display"])
    if "remote_approvals" in stored:
        out["remote_approvals"] = bool(stored["remote_approvals"])
    if "remote_instructions" in stored:
        out["remote_instructions"] = bool(stored["remote_instructions"])
    out["agent_live"] = _merge_agent_live(stored.get("agent_live"))
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


def _send_coding_photon(text: str) -> bool:
    """Send a coding notification over iMessage via the Photon plugin, server-side.

    Routes through ``send_message_tool`` with the bare ``photon`` target, which
    resolves to the Photon home channel (PHOTON_NOTIFY_TARGET) and falls through
    to the plugin's standalone sender → the localhost sidecar. No-ops to False
    when Photon isn't configured. Never raises."""
    try:
        import json as _json

        from tools.send_message_tool import send_message_tool
        res = _json.loads(send_message_tool(
            {"action": "send", "target": "photon", "message": text}))
        return bool(res.get("success"))
    except Exception:
        return False


def _send_coding_device_notify(channel_key: str, title: str, body: str, app: str = "",
                               banner: bool = True) -> bool:
    """Send a notification card to a device channel (glasses, ring, etc.) via the
    mobile device bridge. The phone receives a push with ``type: device_notify``
    and routes by ``channel`` to the right wearable. The push also wakes the app:
    an alert alone runs no app code while the phone is locked, so the card only
    reached the glasses when the ESP32 relay happened to be running.
    ``banner=False``: the phone already shows its own banner for this — wake
    only, no second one. No-ops to False when no mobile device is registered or
    unreachable. Never raises."""
    sent = 0
    try:
        from api.pairing import list_devices
        from api import push as push_mod
    except Exception:
        return False
    try:
        devices = list_devices()
    except Exception:
        return False
    for d in devices:
        try:
            token = (d.get("push_token") or "").strip()
            kind = (d.get("push_kind") or "").strip().lower()
            if not token or kind != "apns":
                continue
            if not (d.get("kind") or "").strip().lower().startswith("mobile"):
                continue
            res = push_mod.send(kind, token,
                                {"type": "device_notify", "channel": channel_key,
                                 "notify_title": title, "notify_body": body,
                                 **({"notify_app": app} if app else {})},
                                alert={"title": title, "body": body, "wake": True} if banner else None)
            if res.get("ok"):
                sent += 1
        except Exception:
            continue
    return sent > 0


def _alert_debounce_ok(sid: str, event: str) -> bool:
    """Whether a phone-style ping (mobile push / Telegram) for ``(sid, event)`` is
    allowed right now — and record it if so. Debounces a session that rapidly
    re-asserts the same edge (don't wake the phone every few seconds). No session
    identity → always allowed (can't safely key, and unrelated sessions must not
    collide). Shared by the mobile + Telegram channels so one edge pings once."""
    import time as _t
    now = _t.monotonic()
    # Bound the map on a long-running server (one entry per session×event).
    if len(_last_alert) > 256:
        cutoff = now - 10 * _ALERT_DEBOUNCE
        for k in [k for k, ts in _last_alert.items() if ts < cutoff]:
            _last_alert.pop(k, None)
    if not sid:
        return True
    key = f"{sid}\x1f{event}"
    if now - _last_alert.get(key, 0.0) < _ALERT_DEBOUNCE:
        return False
    _last_alert[key] = now
    return True


def _dispatch_coding_notifications(store, *, event: str, row, cwd: str = "") -> dict:
    """Fan a coding lifecycle event out to the channels enabled in the Code Master
    matrix. Static channels (telegram, mobile, toast, photon) plus any dynamic
    device channels (glasses, ring, etc.) registered over the device bridge. This
    is the SINGLE source of truth for coding notifications — every channel is gated
    here by the per-event matrix, for BOTH the server host and the Mac (the Mac's
    old client-side notify.sh path, which fired Telegram regardless of the matrix,
    is retired). ``row`` is the session as the hook tracker describes it (None
    is fine: the label falls back to the cwd folder). Returns {channel: bool}.
    Never raises."""
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
    # Mobile push + Telegram are "phone pings": debounce per (session, event) so a
    # session that rapidly re-asserts the same edge can't spam them. Computed once
    # and shared, so one edge fires both channels together (or suppresses both).
    sid = (row or {}).get("id") or cwd
    _phone_allowed = None

    def _phone_ok() -> bool:
        nonlocal _phone_allowed
        if _phone_allowed is None:
            _phone_allowed = _alert_debounce_ok(sid, event)
        return _phone_allowed

    # The iPhone's Focus filter ("only approvals and questions"): while it's on,
    # finished / failed don't ring the phone; what waits on you still does.
    focus_mutes = False
    if event in ("stop", "error"):
        try:
            focus_mutes = bool((store.get_setting("agents_focus", None) or {}).get("only_waiting"))
        except Exception:
            focus_mutes = False
    static_keys = {c["key"] for c in _STATIC_NOTIFY_CHANNELS}
    devices = sorted((k for k, on in chans.items() if on and k not in static_keys),
                     key=lambda k: k != "glasses")
    if chans.get("mobile") and focus_mutes:
        sent["mobile"] = False
    elif chans.get("mobile"):
        if not _phone_ok():
            sent["mobile"] = False
        else:
            # The glasses card rides on the phone's banner: one push, and the app
            # it wakes puts the card on the lens.
            card = devices[0] if devices else None
            data = {"type": "coding", "notify_channel": card, "notify_title": title,
                    "notify_body": label or ""} if card else None
            try:
                sent["mobile"] = _push_device_alert(title, label, data=data, wake=bool(card)) > 0
            except Exception:
                sent["mobile"] = False
            if card and sent["mobile"]:
                sent[card] = True
    if chans.get("telegram"):
        # Telegram lives here (matrix-gated), for every host: the hook tracker
        # reports each session's edges. Unchecking Telegram in the matrix
        # actually stops the ping — that's the point of consolidating it here.
        if not _phone_ok():
            sent["telegram"] = False
        else:
            try:
                sent["telegram"] = _send_coding_telegram(
                    f"{title} — {label}" if label else title)
            except Exception:
                sent["telegram"] = False
    if chans.get("toast"):
        try:
            _notify_webui_event(event=event, label=label, title=title)
            sent["toast"] = True
        except Exception:
            sent["toast"] = False
    if chans.get("photon"):
        # iMessage via the Photon plugin — server-side (the webui can reach the
        # localhost sidecar), like mobile/toast. Send the same title+label text
        # the messaging channels use.
        try:
            sent["photon"] = _send_coding_photon(f"{title} — {label}" if label else title)
        except Exception:
            sent["photon"] = False
    for ch_key in chans:
        if ch_key in static_keys or ch_key in sent:
            continue
        if chans.get(ch_key):
            try:
                sent[ch_key] = _send_coding_device_notify(ch_key, title, label or "")
            except Exception:
                sent[ch_key] = False
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


class _StoreHolder:
    """What ``default_manager()`` hands out now: just the shared store."""

    __slots__ = ("store",)

    def __init__(self, store) -> None:
        self.store = store


_HOLDER = None
_HOLDER_LOCK = threading.Lock()


def default_manager(host: str = "server"):
    """The shared coding store, as ``default_manager().store`` (one
    ``CodingSessionStore`` per process). The name stays for its callers; sessions
    are run by the Agents layer, so ``host`` no longer matters."""
    global _HOLDER
    with _HOLDER_LOCK:
        if _HOLDER is None:
            from agent.coding_session_db import CodingSessionStore
            _HOLDER = _StoreHolder(CodingSessionStore())
        return _HOLDER


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


# A conversation's hook state -> what the island's session rows read.
_FLEET_ACTIVITY = {"working": "working", "thinking": "working",
                   "approval": "waiting", "question": "waiting"}
_FLEET_STATUS = {"live": "running", "ended": "stopped"}   # asleep / offline / moving: paused


def _fleet_session(conv: dict, hook_state=None) -> dict:
    """One Agents conversation in the ``/projects?expand=sessions`` session shape
    the iPhone's Live Activity reads (``CodingSession``): ``status`` running for a
    live session (anything else isn't live there), ``activity_state`` working /
    waiting / idle from its hooks."""
    status = str(conv.get("status") or "live")
    owner = conv.get("owner") or "server"
    live = status == "live"
    state = str(hook_state or conv.get("state") or "")
    return {
        "id": conv.get("ckey") or "", "agent": conv.get("agent") or "claude",
        "title": conv.get("title"), "status": _FLEET_STATUS.get(status, "paused"),
        "activity_state": _FLEET_ACTIVITY.get(state, "idle") if live else None,
        "host": "server" if owner == "server" else "desktop",
        "device_id": None if owner == "server" else owner,
        "cwd": conv.get("cwd") or "", "project_id": conv.get("project_id"),
        "claude_session_id": conv.get("session_id"), "source": "agent",
        "external": owner != "server", "attached": 1,
        "last_activity_at": conv.get("last_event_at") or conv.get("updated_at"),
        "created_at": conv.get("created_at"),
    }


def _conversation_sessions(store, *, live_only: bool) -> list:
    """The coding sessions for ``/projects?expand=sessions``: the Agents
    conversation records (visible ones; only live ones with ``live_only``), their
    state from the hook tracker. Jarvis's own chats aren't coding sessions."""
    from agent.agent_conversations import Conversations
    from agent.coding_la_push import _tracked_states
    hook_states = _tracked_states()
    out = []
    for conv in Conversations(store).list_visible():
        if (conv.get("agent") or "") == "jarvis":
            continue
        if live_only and conv.get("status") != "live":
            continue
        out.append(_fleet_session(conv, hook_states.get((conv.get("agent"),
                                                         conv.get("session_id")))))
    return out


def _hook_owned(claude_session_id: str) -> bool:
    """True when the hook tracker follows this session: its own arbiter (jc-hook)
    then owns the session's approvals."""
    if not claude_session_id:
        return False
    try:
        from agent.agent_tracking import tracker
        tr = tracker()
        return bool(tr) and any(s.get("session_id") == claude_session_id
                                for s in tr.sessions())
    except Exception:  # noqa: BLE001
        return False


def _apply_project_sync(store, pid: str, before: dict, proj: dict, fields: dict) -> None:
    """A project's sync settings changed: its folder sync follows now. The
    project owns the sync (Mac folder <-> its server copy), not a session.
    Switching it off is remembered so auto-sync never turns it back on. Best
    effort; never raises into the request."""
    try:
        from agent import transcript_mirror as tm
        from api import coding_desktop as cd
    except Exception:  # noqa: BLE001
        return
    on = bool(proj.get("sync_enabled"))
    if "sync_enabled" in fields:
        try:
            from agent.agent_sync_policy import SWITCHED_OFF_SETTING
            off = set(store.get_setting(SWITCHED_OFF_SETTING, []) or [])
            if on:
                off.discard(pid)
            else:
                off.add(pid)
            store.set_setting(SWITCHED_OFF_SETTING, sorted(off))
        except Exception:  # noqa: BLE001
            pass

    def pair(p):
        return ((p.get("device_id") or "").strip(),
                (p.get("sync_desktop_path") or p.get("repo_path") or "").strip())

    old_dev, old_local = pair(before or {})
    new_dev, new_local = pair(proj)
    try:
        if before and before.get("sync_enabled") and old_dev and old_local and (
                not on or (old_dev, old_local) != (new_dev, new_local)):
            cd.stop_folder_sync(old_dev, old_local, tm.server_cwd_for(old_local))
        if on and new_dev and new_local:
            from api.agents_core import _start_folder_sync
            _start_folder_sync(new_dev, new_local, tm.server_cwd_for(new_local))
    except Exception:  # noqa: BLE001
        log.warning("project %s sync change failed", pid, exc_info=True)


def _run(fn) -> tuple[int, dict]:
    """Invoke a route body, mapping exceptions to status codes.

    ``KeyError`` (an unknown id) -> 404; any other exception -> 500. ``fn`` returns the success ``(status, payload)`` tuple.
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

    ``manager`` holds the shared store (``manager.store``); ``manager_for_host``
    is accepted for old callers and unused.
    """
    method = (method or "").upper()
    body = body or {}
    p, query = _split_path(path)

    # ── /agents/* — the Agents layer (iPhone Agents tab, web panel, Mac island) ──
    if p.startswith("/agents/"):
        from api.agents_routes import handle_agents_request
        return handle_agents_request(method, p, query, body, manager=manager)

    # ── /projects ──
    if p == "/projects":
        if method == "GET":
            expand = (query.get("expand") or "") == "sessions"
            # ?live=1 — only the live sessions and the projects holding them: what the iPhone's
            # island polls every 5 s (the whole list was 3.8 MB for 1,000 sessions).
            live_only = expand and (query.get("live") or "") in ("1", "true")

            def _list_projects():
                all_projects = manager.store.list_projects()
                active = [p for p in all_projects if not p.get("ignored")]
                ignored = [p for p in all_projects if p.get("ignored")]
                if expand:
                    known = {proj["id"] for proj in all_projects}
                    by_pid = {}
                    for s in _conversation_sessions(manager.store, live_only=live_only):
                        pid = s.get("project_id") if s.get("project_id") in known else None
                        by_pid.setdefault(pid, []).append(s)
                    for proj in all_projects:
                        proj["sessions"] = by_pid.get(proj["id"], [])
                    # Sessions with no project surface in a synthetic bucket so
                    # nothing is hidden. Ignored projects' own sessions stay
                    # attached to them (shown under the Ignored menu).
                    orphans = by_pid.get(None, [])
                    if live_only:
                        return _ok({"projects": [p for p in active if p["sessions"]],
                                    "ungrouped": orphans})
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

    # ── /project/<id> ──
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
                before = manager.store.get_project(pid) or {}
                manager.store.update_project(pid, **fields)
                proj = manager.store.get_project(pid)
                # The project owns its folder sync: a change applies now.
                if sync_changed:
                    _apply_project_sync(manager.store, pid, before, proj or {}, fields)
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
                    try:
                        if cascade:
                            manager.store.delete_session(s["id"])
                        else:
                            manager.store.update_session(s["id"], project_id=None)
                    except Exception:  # noqa: BLE001
                        pass
                manager.store.delete_project(pid)
                return _ok({"ok": True})

            return _run(_delete_project)

        return _err(404, "not found")

    # ── /usage ── (just the account usage block, for the Live Activity rings)
    if p == "/usage":
        if method == "GET":
            return _run(lambda: _ok({"usage": _coding_usage()}))
        return _err(404, "not found")

    # ── /dir-suggest ── typeahead for the New-session WORKING DIRECTORY and
    # "folder path on that device" fields. ``host=server`` (default) lists the
    # SERVER's filesystem; a ``device_id`` (or ``host=desktop``) lists that
    # paired device's filesystem over the bridge. Always returns {dirs:[...]}.
    if p == "/dir-suggest":
        if method != "GET":
            return _err(404, "not found")
        path = query.get("path") or ""
        host = (query.get("host") or "server").strip()
        device_id = (query.get("device_id") or "").strip()

        def _dir_suggest():
            if device_id or host == "desktop":
                from api.coding_desktop import (get_desktop_bridge,
                                                resolve_desktop_device_id)
                did = device_id or (resolve_desktop_device_id() or "")
                if not did:
                    return _ok({"dirs": [], "host": "desktop",
                                "error": "no connected device"})
                dirs = get_desktop_bridge().request_dir_list(did, path=path)
                if dirs is None:
                    return _ok({"dirs": [], "host": "desktop", "device_id": did,
                                "error": "device offline or timed out"})
                return _ok({"dirs": dirs, "host": "desktop", "device_id": did})
            from agent.coding_dir_suggest import suggest_dirs
            return _ok({"dirs": suggest_dirs(path), "host": "server"})

        return _run(_dir_suggest)

    # ── /settings ── Code Master notification matrix + usage-display toggle.
    # GET returns the effective settings (defaults overlaid with stored); POST
    # validates against the known events/channels and persists.
    if p == "/settings":
        if method == "GET":
            return _run(lambda: _ok({"settings": _coding_settings(manager.store),
                                     "available_channels": _available_notify_channels()}))
        if method == "POST":
            def _save_settings():
                incoming = dict(body) if isinstance(body, dict) else {}
                # A switch the saving app doesn't send (an older build, the web
                # page) keeps its stored value instead of falling back to off.
                current = _coding_settings(manager.store)
                for key in ("events", "usage_display", "remote_approvals",
                            "remote_instructions"):
                    incoming.setdefault(key, current.get(key))
                # A partial agent_live (the phone's Dynamic Island tab sends only
                # what it changed) overlays the stored one, key by key.
                from agent.agent_la_push import merge_settings as _merge_agent_live
                incoming["agent_live"] = _merge_agent_live(incoming.get("agent_live"),
                                                           base=current.get("agent_live"))
                merged = _merge_notify_settings(incoming)
                manager.store.set_setting("notifications", merged)
                try:  # the Macs' hook arbiters follow the remote-approvals switch
                    from api import agent_hooks
                    agent_hooks.broadcast_config(merged)
                except Exception:  # noqa: BLE001
                    pass
                # Turning agents (or the whole feature) on/off applies now, not on
                # the next state change.
                _tick_agent_las_soon()
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
                # Push current state to the freshly-registered token immediately
                # (force past the dedupe/rate-limit — a new token otherwise waits
                # for the next change to receive the activity).
                try:
                    from agent.coding_la_push import push_coding_update
                    push_coding_update(manager.store, usage=_coding_usage(),
                                       force=True)
                except Exception:
                    pass
                # If a custom Dynamic Island design is PINNED, force-push it AFTER
                # the coding push so the new token gets the pinned design (the
                # shared activity is last-write-wins).
                try:
                    from api import island_la_push
                    from api.island_store import store_for_request
                    isl = store_for_request()
                    sel = isl.get_selection()
                    pid = sel.get("pinnedId")
                    if (sel.get("mode") == "pinned"
                            and pid not in (None, "", "voice", "coding")):
                        island_la_push.push_design_update(
                            isl, manager.store, pid, force=True)
                except Exception:
                    pass
                return _ok({"ok": True})
            return _run(_store)
        return _err(404, "not found")

    # ── /agent-la/* ── per-agent Live Activities (agent/agent_la_push.py).
    # GET  /agent-la/state → {settings, activities: [{agent, episode, state}]}:
    #      what the foregrounded app starts / updates / ends on its own.
    # POST /agent-la/token {kind, token, device_id, agent?, ended?, dismissed?}:
    #      kind "start"    — the phone's push-to-start token (iOS 17.2+);
    #      kind "activity" — one running activity's push token (or ended=True);
    #      kind "device"   — ended=True: this phone turned Live Activities off.
    if p == "/agent-la/state":
        if method == "GET":
            return _run(lambda: _ok(_agent_la_pusher(manager.store).snapshot()))
        return _err(404, "not found")

    if p == "/agent-la/token":
        if method == "POST":
            return _run(lambda: _agent_la_token(manager.store, body or {}))
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
                    if not token or kind != "apns":
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

    # ── Remote permission approval relay (PreToolUse hook ⇄ mobile) ──
    # The hook (via `jc-client coding-permission`) POSTs a request; we push an
    # actionable banner to the phone and HOLD it; the app POSTs a verdict; the
    # hook polls /poll and applies it. Gated by the `remote_approvals` setting
    # so it never hangs an at-the-terminal session.
    if p == "/permission/request" and method == "POST":
        def _perm_request():
            from api import coding_permission
            if not _coding_settings(manager.store).get("remote_approvals"):
                return _ok({"ok": True, "request_id": None, "notified": 0,
                            "disabled": True})
            tool = (body.get("tool") or "").strip() or "tool"
            tinput = body.get("input") if isinstance(body.get("input"), dict) else {}
            sid = (body.get("claude_session_id") or "").strip()
            # jc-hook's arbiter owns the approvals of a session the hooks follow.
            if _hook_owned(sid):
                return _ok({"ok": True, "request_id": None, "notified": 0,
                            "disabled": True})
            cwd = (body.get("cwd") or "").strip()
            summary = _permission_summary(tool, tinput)
            rid = coding_permission.create_request(
                tool=tool, summary=summary, session_id=sid, cwd=cwd)
            notified = _push_permission_alert(
                title="Claude needs approval",
                body=summary,
                data={"type": "coding_permission", "request_id": rid,
                      "session_id": sid, "tool": tool, "summary": summary,
                      "project": _folder_label(cwd)})
            return _ok({"ok": True, "request_id": rid, "notified": notified})
        return _run(_perm_request)

    if p == "/permission/poll" and method == "GET":
        def _perm_poll():
            from api import coding_permission
            rid = (query.get("request_id") or "").strip()
            if not rid:
                return _err(400, "request_id required")
            return _ok(coding_permission.poll(rid))
        return _run(_perm_poll)

    if p == "/permission/verdict" and method == "POST":
        def _perm_verdict():
            from api import coding_permission
            rid = (body.get("request_id") or "").strip()
            decision = (body.get("decision") or "").strip().lower()
            message = body.get("message") or ""
            answers = body.get("answers") if isinstance(body.get("answers"), dict) else None
            ok = coding_permission.resolve(rid, decision=decision, message=message,
                                           answers=answers)
            return _ok({"ok": ok})
        return _run(_perm_verdict)

    if p == "/permission/pending" and method == "GET":
        def _perm_pending():
            from api import coding_permission
            return _ok({"pending": coding_permission.list_pending()})
        return _run(_perm_pending)

    return _err(404, "not found")
