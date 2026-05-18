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
    """Request a skill execution on the named device. Blocks up to
    ``timeout`` seconds for the device to respond.

    Returns one of:
      {"ok": True, "result": <any>}
      {"ok": False, "error": "..."}
    """
    with _REG_LOCK:
        c = _REG.get(device_id)
    if not c or c.closed:
        return {"ok": False, "error": "device not connected"}
    # Make sure the device actually registered this skill.
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


_RECV_CHUNK = 8192
_MAX_FRAME_BYTES = 256 * 1024  # 256 KB — generous for tool args/results
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
                try:
                    msg = json.loads(event.data or "{}")
                except Exception:
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
        conn.skills = clean[:64]  # cap so a misbehaving device can't bloat the registry
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
    if t == "ping":
        try:
            _ws_send_text(conn, json.dumps({"type": "pong"}))
        except Exception:
            pass
        return
    if t == "pong":
        return
    # Unknown type — ignore (forward-compat).
