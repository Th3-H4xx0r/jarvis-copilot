"""Device bridge — paired devices can advertise their own skills to the
agent via a long-lived WebSocket.

Connect:
    GET /api/devices/bridge/ws
    Cookie: hermes_session=<value>

The session cookie's token prefix is matched against a device record in
``.devices.json``; if no match, the connection is closed. Once paired,
the device speaks a tiny JSON protocol:

    Server → Device:   {"type":"hello","device_id":"..."}
    Device → Server:   {"type":"register","skills":[
                          {"name":"send_sms","description":"...","input_schema":{...}}
                       ]}
    Server → Device:   {"type":"invoke","call_id":"...","skill":"...","args":{...}}
    Device → Server:   {"type":"result","call_id":"...","result":{...}}
                  or:  {"type":"error","call_id":"...","error":"..."}
    Either way:        {"type":"ping"} / {"type":"pong"}

The agent (or any authed caller) invokes a device skill through
``invoke_skill(device_id, skill_name, args, timeout)`` which does the
request/response correlation. Result delivery is synchronous from the
caller's perspective; under the hood the bridge pump thread fulfills a
``threading.Event`` keyed by ``call_id``.
"""
from __future__ import annotations

import http.cookies
import json
import logging
import secrets
import threading
import time
import uuid
from typing import Optional

logger = logging.getLogger(__name__)


# ── Connection registry ─────────────────────────────────────────────────────

class _DeviceConn:
    """Per-device state held in the registry."""

    def __init__(self, device_id: str, sock, conn, name: str = ""):
        self.device_id = device_id
        self.name = name or "device"
        self.sock = sock
        self.conn = conn
        self.skills: list[dict] = []
        self.send_lock = threading.Lock()
        # call_id -> {"event": Event, "result": ..., "error": ...}
        self.pending: dict[str, dict] = {}
        self.pending_lock = threading.Lock()
        self.connected_at = time.time()
        self.last_seen = time.time()
        self.closed = False
        # session_id -> {"on_frame": callable(str), "on_event": callable(str, dict)}
        # Used by the MCP-relay channel (Phase 2): tunnels MCP JSON-RPC frames
        # to a Playwright MCP running on the device. Separate from `pending`
        # (which is request/response invokes).
        self.relay_sessions: dict[str, dict] = {}
        self.relay_lock = threading.Lock()
        # Set when the device announces it can host an MCP relay (Phase 2
        # auto-register): the MCP host synthesizes a relay server for it.
        self.relay_capable = False
        self.relay_meta: dict = {}
        # wsproto delivers a TextMessage event per recv chunk for a
        # multi-chunk WS frame, with `message_finished=True` only on the
        # final piece. We accumulate text data here until the full
        # message arrives before parsing JSON.
        self._text_buf: str = ""


_REG: dict[str, _DeviceConn] = {}
_REG_LOCK = threading.Lock()


def _register(conn: _DeviceConn) -> None:
    with _REG_LOCK:
        # If a previous connection from this device is still around, drop it.
        old = _REG.get(conn.device_id)
        if old and old is not conn:
            _safe_close(old)
        _REG[conn.device_id] = conn


def _unregister(device_id: str, conn: Optional[_DeviceConn] = None) -> None:
    with _REG_LOCK:
        cur = _REG.get(device_id)
        if cur and (conn is None or cur is conn):
            _REG.pop(device_id, None)


def _safe_close(conn: _DeviceConn) -> None:
    conn.closed = True
    try:
        conn.sock.shutdown(2)
    except Exception:
        pass
    try:
        conn.sock.close()
    except Exception:
        pass
    # Wake any callers waiting on pending invocations from this device.
    with conn.pending_lock:
        for entry in conn.pending.values():
            entry["error"] = "device disconnected"
            entry["event"].set()
        conn.pending.clear()
    # Tear down any live MCP-relay sessions so the server-side transport unblocks.
    with conn.relay_lock:
        sessions = list(conn.relay_sessions.items())
        conn.relay_sessions.clear()
    for _sid, sess in sessions:
        cb = sess.get("on_event")
        if cb:
            try:
                cb("closed", {"reason": "device disconnected"})
            except Exception:
                pass


# ── Public API used by routes ───────────────────────────────────────────────

def connected_device_ids() -> list[str]:
    with _REG_LOCK:
        return [d for d, c in _REG.items() if not c.closed]


def skills_for_device(device_id: str) -> list[dict]:
    with _REG_LOCK:
        c = _REG.get(device_id)
        if not c or c.closed:
            return []
        # Return a copy so callers can't mutate registry state.
        return [dict(s) for s in c.skills]


def all_device_skills() -> list[dict]:
    """Flat list of every skill registered by every connected device.
    Each entry includes ``device_id`` and ``device_name`` so the caller
    can disambiguate when two devices register the same skill name."""
    out = []
    with _REG_LOCK:
        for did, c in _REG.items():
            if c.closed:
                continue
            for s in c.skills:
                out.append({
                    "device_id": did,
                    "device_name": c.name,
                    **s,
                })
    return out


def disconnect_device(device_id: str) -> bool:
    """Force-disconnect a device (called when a user revokes / logs it
    out). Returns True if a connection was closed."""
    with _REG_LOCK:
        c = _REG.pop(device_id, None)
    if c:
        _safe_close(c)
        return True
    return False


def invoke_skill(device_id: str, skill_name: str, args: dict,
                 timeout: float = 30.0) -> dict:
    """Request a skill execution on the named device.

    Three paths, in order of preference:

    1. **Live WS** — device has a current bridge connection. Send the
       invoke frame and wait on the per-call Event (same as before).
    2. **Mobile push fallback** — device has no WS but is a mobile record
       with a registered push token. Queue the invoke in
       ``_pending_mobile_invokes[device_id]``, wake the app via
       silent FCM/APNs, and wait on a futures-Event the
       ``/api/devices/mobile/result`` endpoint will resolve.
    3. **Disconnected** — neither path is available; surface a
       device-offline error so the agent can pick another tool.

    Returns one of:
      {"ok": True, "result": <any>}
      {"ok": False, "error": "..."}
    """
    with _REG_LOCK:
        c = _REG.get(device_id)
    if c and not c.closed:
        return _invoke_via_ws(c, skill_name, args, timeout=timeout)
    # No live WS — try the mobile push path.
    return _invoke_via_mobile_push(device_id, skill_name, args, timeout=timeout)


def _invoke_via_ws(c: "_DeviceConn", skill_name: str, args: dict,
                   timeout: float) -> dict:
    if not any(s.get("name") == skill_name for s in c.skills):
        return {"ok": False, "error": f"device has no skill named {skill_name!r}"}

    call_id = secrets.token_hex(8)
    ev = threading.Event()
    holder = {"event": ev, "result": None, "error": None}
    with c.pending_lock:
        c.pending[call_id] = holder

    frame = json.dumps({
        "type": "invoke",
        "call_id": call_id,
        "skill": skill_name,
        "args": args or {},
    })
    try:
        _ws_send_text(c, frame)
    except Exception as exc:
        with c.pending_lock:
            c.pending.pop(call_id, None)
        return {"ok": False, "error": f"send failed: {exc}"}

    ok = ev.wait(timeout=timeout)
    with c.pending_lock:
        c.pending.pop(call_id, None)
    if not ok:
        return {"ok": False, "error": "device did not respond before timeout"}
    if holder["error"]:
        return {"ok": False, "error": str(holder["error"])}
    return {"ok": True, "result": holder["result"]}


# ── MCP relay channel (Phase 2) ─────────────────────────────────────────────
#
# Tunnels MCP JSON-RPC frames between a server-side MCP transport and a
# Playwright MCP process running on the device. The bridge is a dumb pipe: it
# carries opaque `data` strings (one JSON-RPC message each) in both directions
# and routes them to the registered session callbacks. See
# tools/mcp_relay_transport.py (server side) and the desktop client's
# mcp_relay.py (device side).


def open_relay(device_id: str, on_frame, on_event=None,
               meta: Optional[dict] = None) -> Optional[str]:
    """Open an MCP-relay session to a connected device.

    ``on_frame(data: str)`` is called (from the bridge pump thread) for every
    inbound ``mcp_frame``. ``on_event(kind: str, payload: dict)`` is called for
    ``ready`` / ``error`` / ``closed``. Returns the new session_id, or None if
    the device isn't connected / the open frame couldn't be sent.
    """
    with _REG_LOCK:
        c = _REG.get(device_id)
    if not c or c.closed:
        return None
    session_id = secrets.token_hex(8)
    with c.relay_lock:
        c.relay_sessions[session_id] = {"on_frame": on_frame, "on_event": on_event}
    try:
        _ws_send_text(c, json.dumps({
            "type": "mcp_open",
            "session": session_id,
            "meta": meta or {},
        }))
    except Exception:
        with c.relay_lock:
            c.relay_sessions.pop(session_id, None)
        return None
    return session_id


def relay_send_frame(device_id: str, session_id: str, data: str) -> bool:
    """Send one JSON-RPC frame to the device's relay session. Returns False if
    the device is gone or the send failed."""
    with _REG_LOCK:
        c = _REG.get(device_id)
    if not c or c.closed:
        return False
    with c.relay_lock:
        live = session_id in c.relay_sessions
    if not live:
        return False
    try:
        _ws_send_text(c, json.dumps({
            "type": "mcp_frame",
            "session": session_id,
            "data": data,
        }))
        return True
    except Exception:
        return False


def close_relay(device_id: str, session_id: str) -> None:
    """Close an MCP-relay session and tell the device to stop the child."""
    with _REG_LOCK:
        c = _REG.get(device_id)
    if not c:
        return
    with c.relay_lock:
        existed = c.relay_sessions.pop(session_id, None) is not None
    if existed:
        try:
            _ws_send_text(c, json.dumps({
                "type": "mcp_close",
                "session": session_id,
            }))
        except Exception:
            pass


def _relay_session(conn: "_DeviceConn", session_id) -> Optional[dict]:
    if not session_id:
        return None
    with conn.relay_lock:
        return conn.relay_sessions.get(session_id)


# ── Coding-session channel (Phase 4: desktop-host coding sessions) ───────────
#
# A desktop-host coding session drives tmux+claude on the paired desktop client
# and streams its PTY + a bidirectional file sync over the bridge. The webui
# process sends ``coding_term_*`` / ``coding_sync_*`` frames to the device and
# routes the device's replies to a registered handler. Unlike the MCP relay
# (one session_id per channel) and invokes (call_id correlation), coding frames
# are routed by their own ``term_id`` / ``sync_id`` *inside* the frame, so the
# bridge just forwards the whole frame to a single process-wide subscriber
# (api.coding_desktop.DesktopBridge) which fans out by id.

# Frame types the device sends back that belong to the coding channel.
_CODING_INBOUND_TYPES = frozenset({
    "coding_term_output", "coding_term_exit",
    "coding_sync_manifest", "coding_sync_file", "coding_sync_event",
})

# process-wide handler(device_id: str, frame: dict) -> None, set by DesktopBridge.
_coding_frame_handler = None
_coding_handler_lock = threading.Lock()


def set_coding_frame_handler(handler) -> None:
    """Register the process-wide inbound coding-frame handler.

    ``handler(device_id, frame)`` is invoked (from the bridge pump thread) for
    every inbound ``coding_term_*`` / ``coding_sync_*`` frame. Passing ``None``
    clears it. Only one handler is supported — the webui's DesktopBridge owns it.
    """
    global _coding_frame_handler
    with _coding_handler_lock:
        _coding_frame_handler = handler


def send_frame(device_id: str, frame: dict) -> bool:
    """Send an arbitrary JSON frame to a connected device. Returns False if the
    device isn't connected or the send failed.

    This is the generic streaming (non-invoke) send path used by the coding
    channel. Unlike ``invoke_skill`` it does not wait for a reply — replies
    arrive asynchronously as their own inbound frames and are routed by
    ``set_coding_frame_handler``.
    """
    with _REG_LOCK:
        c = _REG.get(device_id)
    if not c or c.closed:
        return False
    try:
        _ws_send_text(c, json.dumps(frame))
        return True
    except Exception:
        return False


def _dispatch_coding_frame(conn: "_DeviceConn", msg: dict) -> None:
    with _coding_handler_lock:
        handler = _coding_frame_handler
    if handler is None:
        return
    try:
        handler(conn.device_id, msg)
    except Exception as exc:
        logger.debug("coding frame handler raised: %s", exc)


def relay_capable_devices() -> list[dict]:
    """Connected devices that announced MCP-relay capability.

    Returns ``[{"device_id", "device_name", "meta"}]`` — consumed by the MCP
    host's config loader to auto-register a relay server per device.
    """
    out: list[dict] = []
    with _REG_LOCK:
        for did, c in _REG.items():
            if c.closed or not getattr(c, "relay_capable", False):
                continue
            out.append({
                "device_id": did,
                "device_name": c.name,
                "meta": dict(getattr(c, "relay_meta", {}) or {}),
            })
    return out


def _trigger_relay_autoregister() -> None:
    """Re-scan MCP servers in the background so a newly-connected relay-capable
    device's relay server starts without a manual reload. Best-effort; runs off
    the pump thread so a slow connect can't stall the bridge."""
    def _rescan():
        try:
            from tools.mcp_tool import discover_mcp_tools
            discover_mcp_tools()
        except Exception as exc:
            logger.debug("relay autoregister rescan failed: %s", exc)
    threading.Thread(target=_rescan, daemon=True, name="relay-autoregister").start()


def _trigger_coding_resync(device_id: str) -> None:
    """When a (desktop) device (re)connects, re-open the file sync for every
    still-running synced coding session so the manifest-diff reconcile re-checks
    whether any files need re-syncing.

    Best-effort and fully isolated: runs off the bridge pump thread (so a slow
    reconcile can't stall the connection) and swallows every error (so it can
    never break device registration). The resync itself only does meaningful
    work for desktop/synced sessions — non-desktop devices simply find nothing
    to re-open."""
    if not device_id:
        return

    def _run():
        try:
            from api.coding_desktop import resync_device

            n = resync_device(device_id)
            if n:
                logger.info("coding resync: re-opened %d sync(s) for device %s",
                            n, device_id)
        except Exception as exc:
            logger.debug("coding resync failed for %s: %s", device_id, exc)

    threading.Thread(target=_run, daemon=True, name="coding-resync").start()


# ── Mobile push fallback ───────────────────────────────────────────────────
#
# When a mobile client is backgrounded its WS is gone. The bridge falls
# back to:
#   1. Append the invoke envelope to _PENDING_MOBILE[device_id].
#   2. Send a silent push (FCM data / APNs background) telling the app
#      "wake up and poll".
#   3. Block on an Event keyed by call_id; the mobile /result endpoint
#      sets it once the device responds.
#
# Timeout default is generous (30s) because APNs delivery can take a few
# seconds even on a good network, plus the app needs its background
# window to open before it can poll.

_PENDING_MOBILE: dict[str, list[dict]] = {}     # device_id → list of {call_id, skill, args, queued_at, requires_foreground, expires_at}
_PENDING_MOBILE_LOCK = threading.Lock()
_MOBILE_CALL_EVENTS: dict[str, dict] = {}        # call_id → {event, result, error, device_id}
_MOBILE_CALL_EVENTS_LOCK = threading.Lock()
_MOBILE_QUEUE_CAP_PER_DEVICE = 32                # protects against runaway queueing


# Skills whose final action needs the FOREGROUND (they call openURL / platform
# UI). When the phone is backgrounded the live WS manifest is gone, so this set
# — not a per-skill manifest flag — is the source of truth for "send a visible,
# tappable push" vs "silent background push". See the notification-tap bridge spec.
_FOREGROUND_SKILLS = frozenset({
    "phone_control", "open_url", "open_app", "run_shortcut",
    "create_shortcut", "send_sms",
})

# How long a queued, not-yet-tapped invoke stays runnable before it's dropped.
_MOBILE_INVOKE_TTL = 3600.0  # 1 hour


def is_foreground_skill(skill_name: str) -> bool:
    return skill_name in _FOREGROUND_SKILLS


def _pretty_pct(value) -> str:
    try:
        v = float(value)
    except (TypeError, ValueError):
        return str(value)
    if v <= 1:
        v *= 100
    return f"{int(round(v))}%"


def _truthy(value) -> bool:
    return str(value).strip().lower() in ("1", "on", "true", "yes")


def format_action_banner(skill_name: str, args: dict) -> tuple[str, str]:
    """(title, body) for the visible push. Per-skill formatters with a generic
    fallback so no skill is ever unhandled. Title is clamped so a pathological
    URL/app name can't bloat the (4KB-capped) push payload."""
    args = args if isinstance(args, dict) else {}
    body = "Tap to run"
    title = "JARVIS action ready"
    if skill_name == "open_url":
        url = str(args.get("url") or "")
        host = url
        try:
            from urllib.parse import urlparse
            host = urlparse(url).netloc or url
        except Exception:
            pass
        title = f"Open {host}"
    elif skill_name == "open_app":
        title = f"Open {args.get('app') or args.get('name') or 'app'}"
    elif skill_name == "run_shortcut":
        title = f"Run {args.get('name') or 'shortcut'}"
    elif skill_name == "send_sms":
        title = "Send a text"
    elif skill_name == "phone_control":
        action = str(args.get("action") or "")
        value = args.get("value")
        if action in ("brightness", "volume"):
            label = "brightness" if action == "brightness" else "volume"
            title = f"Set {label}" if value is None else f"Set {label} {_pretty_pct(value)}"
        elif action in ("wifi", "bluetooth", "focus"):
            name = {"wifi": "Wi-Fi", "bluetooth": "Bluetooth", "focus": "Focus"}[action]
            title = f"Turn {'on' if _truthy(value) else 'off'} {name}"
        else:
            title = "Phone control"
    return (title[:100], body)


def _invoke_via_mobile_push(device_id: str, skill_name: str, args: dict,
                            timeout: float) -> dict:
    try:
        from api.pairing import list_devices
        from api import push as push_mod
    except Exception as exc:
        return {"ok": False, "error": f"mobile push unavailable: {exc}"}

    device = None
    for d in list_devices():
        if d.get("id") == device_id:
            device = d
            break
    if not device:
        return {"ok": False, "error": "device not connected"}
    push_token = (device.get("push_token") or "").strip()
    push_kind = (device.get("push_kind") or "").strip().lower()
    kind = (device.get("kind") or "").strip().lower()
    if not push_token or push_kind not in ("fcm", "apns"):
        # Not a mobile record (or one that never registered a token).
        return {"ok": False, "error": "device not connected"}
    if not kind.startswith("mobile"):
        return {"ok": False, "error": "device not connected"}

    call_id = secrets.token_hex(8)
    ev = threading.Event()
    holder = {"event": ev, "result": None, "error": None, "device_id": device_id}
    with _MOBILE_CALL_EVENTS_LOCK:
        _MOBILE_CALL_EVENTS[call_id] = holder

    requires_foreground = is_foreground_skill(skill_name)
    with _PENDING_MOBILE_LOCK:
        q = _PENDING_MOBILE.setdefault(device_id, [])
        # Drop oldest entries if a runaway server keeps queueing without the
        # phone draining — protects against unbounded memory growth.
        if len(q) >= _MOBILE_QUEUE_CAP_PER_DEVICE:
            dropped = q.pop(0)
            logger.warning("mobile queue cap reached; dropped %r", dropped.get("call_id"))
        q.append({
            "call_id": call_id,
            "skill": skill_name,
            "args": args or {},
            "queued_at": time.time(),
            "requires_foreground": requires_foreground,
            "expires_at": time.time() + _MOBILE_INVOKE_TTL,
        })

    # Fire-and-forget push. We don't wait on the HTTP response because
    # FCM/APNs delivery is independent of acknowledgement; if the message
    # never lands, the per-call Event will time out below.
    # Foreground-required skills can't run headless, so we send a VISIBLE,
    # tappable banner instead of a silent wake. Tapping it foregrounds the app,
    # which drains the queue and runs the action where openURL works.
    alert = None
    if requires_foreground:
        title, body = format_action_banner(skill_name, args or {})
        alert = {"title": title, "body": body}
    push_ok = False
    push_err = None
    try:
        result = push_mod.send(push_kind, push_token, {
            "type": "invoke_pending",
            "device_id": device_id,
            "count": str(len(q)),
        }, alert=alert)
        push_ok = bool(result.get("ok"))
        if not push_ok:
            push_err = result.get("error")
            logger.warning("push send failed (%s): %s", push_kind, push_err)
            # If the token is unambiguously dead (FCM 404/UNREGISTERED, APNs 410)
            # we surface a clearer error so the agent can move on AND clear
            # the stale token so subsequent invokes don't fire pointless pushes.
            status = result.get("status")
            if status in (404, 410):
                _cleanup_mobile_call(call_id)
                try:
                    from api.pairing import update_device_fields
                    update_device_fields(device_id, push_token="", push_kind="")
                except Exception as exc:
                    logger.warning("could not clear dead push token: %s", exc)
                return {"ok": False, "error": "device push token expired"}
    except Exception as exc:
        push_err = str(exc)
        logger.warning("push dispatch raised: %s", exc)

    if requires_foreground:
        # We can't block a server thread until a human taps the banner. The
        # action runs on the foreground tap; we don't await its result here.
        if not push_ok:
            # The banner never reached the phone — don't tell the user we sent
            # it. Drop the stranded queue entry + waiter and surface the error.
            _cleanup_mobile_call(call_id)
            return {"ok": False,
                    "error": f"could not reach phone ({push_err or 'push failed'})"}
        # Drop only the waiter Event — the queued invoke stays so the app can
        # drain + run it when the user taps.
        _cleanup_mobile_call_event_only(call_id)
        return {"ok": True, "result": {
            "queued": True,
            "note": "Sent to your phone — tap the notification to run it.",
        }}

    ok = ev.wait(timeout=timeout)
    final = _cleanup_mobile_call(call_id)
    if not ok:
        return {"ok": False, "error": "device did not respond before timeout"}
    if final.get("error"):
        return {"ok": False, "error": str(final["error"])}
    return {"ok": True, "result": final.get("result")}


def _cleanup_mobile_call_event_only(call_id: str) -> None:
    """Drop only the waiter Event for a fire-and-forget invoke; the queued
    invoke stays so the app can drain + run it when the user taps."""
    with _MOBILE_CALL_EVENTS_LOCK:
        _MOBILE_CALL_EVENTS.pop(call_id, None)


def _cleanup_mobile_call(call_id: str) -> dict:
    """Remove the call from the events map AND from any device queue.
    Returns the holder so the caller can read the final result/error."""
    with _MOBILE_CALL_EVENTS_LOCK:
        holder = _MOBILE_CALL_EVENTS.pop(call_id, None) or {}
    device_id = holder.get("device_id")
    if device_id:
        with _PENDING_MOBILE_LOCK:
            q = _PENDING_MOBILE.get(device_id)
            if q:
                _PENDING_MOBILE[device_id] = [
                    e for e in q if e.get("call_id") != call_id
                ]
                if not _PENDING_MOBILE[device_id]:
                    _PENDING_MOBILE.pop(device_id, None)
    return holder


# ── Public helpers used by the /api/devices/mobile/* endpoints ─────────────

def take_mobile_queue(device_id: str, include_foreground: bool = True) -> list[dict]:
    """Drain queued invocations for a mobile device.

    Drops invokes past ``expires_at`` (resolving any waiter with an "expired"
    error). When ``include_foreground`` is False (the app polled from its
    BACKGROUND isolate), foreground-required invokes are LEFT queued so the
    isolate never tries to run a foreground action headless — they wait for the
    visible-push tap to bring the app forward.

    Called by ``POST /api/devices/mobile/poll``. Callers send back
    ``{type:"result"|"error"}`` per call_id; if they fail, any per-call Event
    eventually times out.
    """
    now = time.time()
    expired: list[dict] = []
    with _PENDING_MOBILE_LOCK:
        q = _PENDING_MOBILE.get(device_id, [])
        live: list[dict] = []
        kept: list[dict] = []
        for e in q:
            exp = e.get("expires_at") or 0
            if exp and exp < now:
                expired.append(e)
                continue
            if not include_foreground and e.get("requires_foreground"):
                kept.append(e)
                continue
            live.append(e)
        if kept:
            _PENDING_MOBILE[device_id] = kept
        else:
            _PENDING_MOBILE.pop(device_id, None)
    # Resolve expired waiters OUTSIDE the queue lock (resolve takes another lock).
    for e in expired:
        resolve_mobile_result(e.get("call_id", ""),
                              error="expired — phone not tapped in time")
    # Return a shallow copy of each entry so the caller can't mutate
    # remaining state via aliased dicts.
    return [dict(e) for e in live]


def resolve_mobile_result(call_id: str, result=None, error: Optional[str] = None) -> bool:
    """Resolve a queued invocation. Called by /api/devices/mobile/result.
    Returns True if a waiting caller was woken.

    Mutation happens *inside* the lock so a concurrent _cleanup_mobile_call
    (e.g. from a timed-out waiter) can't pop the holder while we're
    halfway through writing to it — which would drop the result on the
    floor or, worse, mix a late error into a holder the caller already
    inspected.
    """
    with _MOBILE_CALL_EVENTS_LOCK:
        holder = _MOBILE_CALL_EVENTS.get(call_id)
        if not holder:
            return False
        if error:
            holder["error"] = error
        else:
            holder["result"] = result
        ev = holder["event"]
    ev.set()
    return True


def pending_mobile_count(device_id: str) -> int:
    with _PENDING_MOBILE_LOCK:
        return len(_PENDING_MOBILE.get(device_id, []))


# ── WS handler (called from server's WS upgrade dispatch) ───────────────────

def handle_websocket(handler, parsed) -> bool:
    """Called from server.do_GET when an upgrade is seen. Returns True iff
    this module claims the path (so the caller knows not to fall through
    to the chat WS handler)."""
    if parsed.path != "/api/devices/bridge/ws":
        return False
    try:
        from wsproto import WSConnection, ConnectionType
        from wsproto.events import Request, AcceptConnection
    except Exception:
        try:
            handler.send_response(503)
            handler.send_header("Content-Type", "application/json")
            handler.end_headers()
            handler.wfile.write(b'{"error":"wsproto not installed"}')
        except Exception:
            pass
        return True

    device = _resolve_device_for_handler(handler)
    if not device:
        try:
            handler.send_response(401)
            handler.send_header("Content-Type", "application/json")
            handler.end_headers()
            handler.wfile.write(b'{"error":"no matching paired device for this session"}')
        except Exception:
            pass
        return True

    sock = handler.connection
    try:
        sock.settimeout(None)
    except Exception:
        pass
    ws = WSConnection(ConnectionType.SERVER)
    raw = _reconstruct_request(handler)
    ws.receive_data(raw)
    accepted = False
    for event in ws.events():
        if isinstance(event, Request):
            try:
                sock.sendall(ws.send(AcceptConnection()))
                accepted = True
            except Exception:
                return True
            break
    if not accepted:
        return True

    conn = _DeviceConn(
        device_id=device["id"],
        sock=sock,
        conn=ws,
        name=device.get("name", "") or "device",
    )
    _register(conn)
    try:
        _ws_send_text(conn, json.dumps({
            "type": "hello",
            "device_id": device["id"],
            "device_name": conn.name,
            "ts": time.time(),
        }))
        # Device-connect hook: a (re)connecting desktop should re-open the file
        # sync for any running synced coding session so it re-reconciles. Fired
        # off-thread + fully defensive so it can never break the connection.
        try:
            _trigger_coding_resync(conn.device_id)
        except Exception:
            pass
        _pump(conn)
    finally:
        _unregister(conn.device_id, conn)
        _safe_close(conn)
    return True


# ── Internals ───────────────────────────────────────────────────────────────

def _resolve_device_for_handler(handler) -> Optional[dict]:
    """Map the request's session cookie back to a paired device record.

    Returns None if there is no valid session OR if no device records
    share that session's token prefix. (Password-only sessions, which
    aren't tied to any device, are intentionally rejected — only paired
    devices may open the bridge.)
    """
    raw = handler.headers.get("Cookie") or ""
    if not raw:
        return None
    try:
        jar = http.cookies.SimpleCookie()
        jar.load(raw)
        morsel = jar.get("hermes_session")
        if not morsel or "." not in morsel.value:
            return None
        token = morsel.value.split(".", 1)[0]
    except Exception:
        return None
    # Don't trust an expired session.
    try:
        from api.auth import verify_session
        if not verify_session(morsel.value):
            return None
    except Exception:
        return None
    prefix = token[:8]
    try:
        from api.pairing import list_devices
    except Exception:
        return None
    matches = [d for d in list_devices() if (d.get("session_prefix") or "") == prefix]
    if not matches:
        return None
    # Newest match wins if multiple devices ever shared a prefix.
    matches.sort(key=lambda d: d.get("paired_at", 0), reverse=True)
    return matches[0]


def _reconstruct_request(handler) -> bytes:
    lines = [f"{handler.command} {handler.path} HTTP/1.1"]
    for k, v in handler.headers.items():
        lines.append(f"{k}: {v}")
    lines.append("")
    lines.append("")
    return ("\r\n".join(lines)).encode("latin-1")


_RECV_CHUNK = 65536  # 64 KB per recv; reassembly handles larger messages
# Hard cap on a single WS message we'll buffer in memory per connection
# — protects against a misbehaving device flooding us. 8 MB is enough
# for an uncompressed-but-downscaled screenshot or a large skill result.
_MAX_FRAME_BYTES = 8 * 1024 * 1024
_PING_INTERVAL = 30.0  # send a server-side ping every 30s


def _ws_send_text(conn: _DeviceConn, text: str) -> None:
    """Send a text frame thread-safely."""
    if conn.closed:
        raise RuntimeError("device closed")
    from wsproto.events import TextMessage
    data = conn.conn.send(TextMessage(data=text))
    with conn.send_lock:
        conn.sock.sendall(data)


def _ws_send_close(conn: _DeviceConn) -> None:
    from wsproto.events import CloseConnection
    try:
        data = conn.conn.send(CloseConnection(code=1000))
        with conn.send_lock:
            conn.sock.sendall(data)
    except Exception:
        pass


def _pump(conn: _DeviceConn) -> None:
    """Receive loop. Dispatches frames; sends periodic pings to detect
    half-open sockets that NAT timeouts can leave behind."""
    from wsproto.events import (
        TextMessage, BytesMessage, CloseConnection, Ping, Pong,
    )
    last_ping = time.time()
    while not conn.closed:
        try:
            data = conn.sock.recv(_RECV_CHUNK)
        except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError,
                TimeoutError, OSError):
            break
        if not data:
            break
        try:
            conn.conn.receive_data(data)
        except Exception as exc:
            logger.debug("device bridge protocol error: %s", exc)
            break
        for event in conn.conn.events():
            conn.last_seen = time.time()
            if isinstance(event, TextMessage):
                # wsproto delivers a TextMessage per recv chunk for a
                # multi-recv WS frame, with `message_finished=True` only
                # on the final piece. We must accumulate text until the
                # message is complete before parsing JSON — otherwise
                # any payload over ~8 KB (one recv chunk) silently
                # never reaches _handle_message because partial JSON
                # fails to parse and we'd `continue`. That was the
                # source of every "device did not respond before
                # timeout" we saw for screenshots and large results.
                conn._text_buf += event.data or ""
                if not getattr(event, "message_finished", True):
                    continue
                raw = conn._text_buf
                conn._text_buf = ""
                if len(raw) > _MAX_FRAME_BYTES:
                    logger.warning(
                        "device %s sent oversize frame (%d B > %d) — dropping",
                        conn.device_id, len(raw), _MAX_FRAME_BYTES,
                    )
                    continue
                try:
                    msg = json.loads(raw or "{}")
                except Exception as exc:
                    logger.debug("bad json frame from device %s: %s", conn.device_id, exc)
                    continue
                _handle_message(conn, msg)
            elif isinstance(event, BytesMessage):
                # Binary frames aren't part of the bridge protocol yet.
                # Drop silently — devices shouldn't send these.
                continue
            elif isinstance(event, Ping):
                try:
                    with conn.send_lock:
                        conn.sock.sendall(conn.conn.send(Pong(payload=event.payload)))
                except Exception:
                    return
            elif isinstance(event, Pong):
                pass  # liveness — already updated last_seen
            elif isinstance(event, CloseConnection):
                return
        # Server-side keepalive ping.
        now = time.time()
        if now - last_ping >= _PING_INTERVAL:
            try:
                with conn.send_lock:
                    conn.sock.sendall(conn.conn.send(Ping(payload=b"")))
                last_ping = now
            except Exception:
                return


def _handle_message(conn: _DeviceConn, msg: dict) -> None:
    t = msg.get("type")
    if t == "register":
        skills = msg.get("skills") or []
        clean: list[dict] = []
        if isinstance(skills, list):
            for s in skills:
                if not isinstance(s, dict):
                    continue
                name = (s.get("name") or "").strip()
                if not name:
                    continue
                clean.append({
                    "name": name[:64],
                    "description": (s.get("description") or "")[:512],
                    "input_schema": s.get("input_schema") if isinstance(s.get("input_schema"), dict) else {"type": "object"},
                })
        # `append=true` extends the existing registry — lets clients with
        # large manifests chunk the registration across multiple frames
        # so each WS message stays well under the recv buffer. Without
        # the flag we treat the frame as authoritative and replace.
        if msg.get("append"):
            merged: dict[str, dict] = {s["name"]: s for s in conn.skills}
            for s in clean:
                merged[s["name"]] = s
            conn.skills = list(merged.values())[:128]
        else:
            conn.skills = clean[:128]  # cap so a misbehaving device can't bloat the registry
        try:
            _ws_send_text(conn, json.dumps({
                "type": "registered",
                "count": len(conn.skills),
            }))
        except Exception:
            pass
        return
    if t == "result":
        call_id = msg.get("call_id")
        if not call_id:
            return
        with conn.pending_lock:
            entry = conn.pending.get(call_id)
        if not entry:
            return
        entry["result"] = msg.get("result")
        entry["event"].set()
        return
    if t == "error":
        call_id = msg.get("call_id")
        if not call_id:
            return
        with conn.pending_lock:
            entry = conn.pending.get(call_id)
        if not entry:
            return
        entry["error"] = msg.get("error") or "device error"
        entry["event"].set()
        return
    if t == "mcp_relay_available":
        conn.relay_capable = True
        conn.relay_meta = msg.get("meta") if isinstance(msg.get("meta"), dict) else {}
        _trigger_relay_autoregister()
        return
    if t == "mcp_frame":
        sess = _relay_session(conn, msg.get("session"))
        if sess and sess.get("on_frame"):
            try:
                sess["on_frame"](msg.get("data") or "")
            except Exception as exc:
                logger.debug("relay on_frame raised: %s", exc)
        return
    if t in ("mcp_ready", "mcp_error", "mcp_closed"):
        kind = t[len("mcp_"):]  # ready | error | closed
        sess = _relay_session(conn, msg.get("session"))
        if t == "mcp_closed":
            with conn.relay_lock:
                conn.relay_sessions.pop(msg.get("session"), None)
        if sess and sess.get("on_event"):
            try:
                sess["on_event"](kind, msg)
            except Exception as exc:
                logger.debug("relay on_event raised: %s", exc)
        return
    if t in _CODING_INBOUND_TYPES:
        _dispatch_coding_frame(conn, msg)
        return
    if t == "ping":
        try:
            _ws_send_text(conn, json.dumps({"type": "pong"}))
        except Exception:
            pass
        return
    if t == "pong":
        return
    # Unknown type — ignore (forward-compat).
