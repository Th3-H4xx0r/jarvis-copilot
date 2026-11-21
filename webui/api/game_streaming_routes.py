"""Game streaming over HTTP (/api/game-streaming, gated by the Game Streaming Power
integration) and the bridge events the PC pushes.

A Sunshine stream is client-initiated, so "start" readies the host (waking the PC
if needed) and points the target device's Moonlight at host+app. When the PC is
asleep, start registers a pending connect and requests a wake; the connect
completes when the PC next reports in. The PC's log watcher pushes stream/device
events here (topic "game_stream"); they update live state + session history and
feed the alerts in api.game_streaming_alerts.
"""
from __future__ import annotations

import time
from typing import Any

_PENDING: list[dict] = []
_clock = time.time


# ── seams (tests replace these) ──────────────────────────────────────────────
def store():
    from api.game_streaming_store import store as _store
    return _store()


def _invoke(did: str, skill: str, args: dict, timeout: float = 20.0) -> dict:
    from api import device_bridge
    return device_bridge.invoke_skill(did, skill, args, timeout=timeout)


def _connected() -> list:
    from api import device_bridge
    return list(device_bridge.connected_device_ids())


def _device_os(did: str) -> str:
    from api import device_bridge
    try:
        return device_bridge.device_os(did)
    except Exception:  # noqa: BLE001
        return ""


def _publish_to(did: str, topic: str, data: dict) -> None:
    from api import device_bridge
    try:
        device_bridge.publish_to(did, topic, data)
    except Exception:  # noqa: BLE001
        pass


def _pc_id() -> str:
    from api.pc_lighting_routes import pc_device_id
    return pc_device_id("")


def _settings() -> dict:
    try:
        from jarvis_power import discovery
        return discovery.get("game-streaming").read_settings() or {}
    except Exception:  # noqa: BLE001
        return {}


def _enabled() -> bool:
    try:
        from jarvis_power import state
        return state.is_on("game-streaming")
    except Exception:  # noqa: BLE001
        return True


def _targets() -> list:
    return list(_settings().get("targets") or [])


def _sunshine_conn() -> dict:
    s = _settings()
    return {"host": s.get("host", ""), "port": int(s.get("port", 47990) or 47990),
            "user": s.get("user", ""), "password": s.get("password", ""),
            "scheme": s.get("scheme", "https")}


def _pending_timeout() -> float:
    try:
        return float(_settings().get("wake_timeout", 1200) or 1200)
    except Exception:  # noqa: BLE001
        return 1200.0


def _skills_of(did: str) -> set:
    from api import device_bridge
    try:
        return set(device_bridge.skills_of(did))  # type: ignore[attr-defined]
    except Exception:  # noqa: BLE001
        return set()


def _current_game():
    """Best-effort: the game running locally on the PC right now, else None."""
    try:
        from api.pc_stats_store import store as pc_store
        latest = pc_store().latest(_pc_id())  # type: ignore[attr-defined]
        return (latest or {}).get("game") or None
    except Exception:  # noqa: BLE001
        return None


def _wake_pc() -> bool:
    try:
        pc = _pc_id()
        for did in _connected():
            if did != pc and "wol_send" in _skills_of(did):
                _invoke(did, "wol_send", {"target": pc})
                return True
    except Exception:  # noqa: BLE001
        pass
    return False


def _device_for_kind(kind: str) -> str:
    """The device whose jc-client drives the connect for this target kind."""
    pc = _pc_id()
    if kind == "androidtv":
        return pc
    if kind == "mac":
        for did in _connected():
            if did != pc and _device_os(did) == "darwin":
                return did
    return pc


# ── helpers ──────────────────────────────────────────────────────────────────
def _online(did: str) -> bool:
    return bool(did) and did in _connected()


def _resolve_target(ref: Any) -> dict | None:
    if isinstance(ref, dict):
        return ref
    name = str(ref or "").strip().lower()
    for t in _targets():
        if str(t.get("name", "")).lower() == name or str(t.get("kind", "")).lower() == name:
            return t
    return None


def _dispatch_connect(pc: str, target: dict, app: str, srs: bool) -> dict:
    kind = target.get("kind")
    if kind == "ios":
        _publish_to(target.get("device_id") or "", "game_stream_tap",
                    {"host": target.get("host"), "app": app})
        return {"ok": True, "status": "tap", "push": True}
    did = _device_for_kind(kind)
    return _invoke(did, "game_stream_connect",
                   {"target": target, "app": app, "stream_running_session": srs}) or {"ok": False}


def complete_pending(pc: str) -> None:
    pending = [p for p in _PENDING if p.get("pc") == pc]
    for p in pending:
        try:
            _dispatch_connect(pc, p["target"], p["app"], p.get("srs", False))
        finally:
            if p in _PENDING:
                _PENDING.remove(p)


def _reap(now: float | None = None) -> None:
    now = _clock() if now is None else now
    for p in list(_PENDING):
        if p.get("deadline", 0) <= now:
            _PENDING.remove(p)


# ── bridge event from the PC ────────────────────────────────────────────────
def _on_event(did: str, data: dict) -> None:
    s = store()
    ev = data or {}
    kind = ev.get("kind")
    if kind == "stream_start":
        s.set_live({"active": True, "client": ev.get("client"), "app": ev.get("app")})
        s.record_session(ev)
    elif kind == "stream_stop":
        s.set_live({"active": False, "client": None, "app": None})
        s.record_session(ev)
    elif kind == "device_connect":
        s.record_session(ev)
    try:
        from api.game_streaming_alerts import emit as _emit
        _emit(ev)
    except Exception:  # noqa: BLE001
        pass
    complete_pending(did)


def register_events() -> None:
    from api import device_bridge
    device_bridge.on_device_event("game_stream", _on_event)


# ── HTTP ─────────────────────────────────────────────────────────────────────
def _public_settings() -> dict:
    s = dict(_settings())
    s.pop("password", None)
    return s


def _handle_status(req, s):
    pc = _pc_id()
    if not _online(pc):
        return req.reply(200, {"ok": True, "reachable": False, "live": s.get_live(),
                               "paired": s.get_paired(), "apps": [], "targets": _targets()})
    res = _invoke(pc, "game_stream_status", {"sunshine": _sunshine_conn()}) or {}
    data = res.get("data") or {}
    try:
        from api import game_streaming_alerts
        game_streaming_alerts.note_reachable(bool(data.get("reachable", False)))
    except Exception:  # noqa: BLE001
        pass
    if data.get("paired"):
        s.upsert_paired(data["paired"])
    return req.reply(200, {"ok": True, "reachable": bool(data.get("reachable", False)),
                           "live": s.get_live(), "paired": s.get_paired(),
                           "apps": data.get("apps", []), "targets": _targets()})


def _handle_start(req, body, s):
    pc = _pc_id()
    target = _resolve_target(body.get("target"))
    app = body.get("game") or body.get("app") or ""
    if not target:
        return req.reply(400, {"ok": False, "error": "unknown target"})
    running = _current_game()
    srs = bool(running)
    if _online(pc):
        _invoke(pc, "game_stream_ready", {"sunshine": _sunshine_conn()})
        res = _dispatch_connect(pc, target, app, srs)
        out = {"ok": bool(res.get("ok", True)), "status": "started", "result": res}
        if srs:
            out["note"] = f"streaming your running session ({running})"
        return req.reply(200, out)
    _wake_pc()
    _PENDING.append({"pc": pc, "target": target, "app": app, "srs": srs,
                     "deadline": _clock() + _pending_timeout()})
    return req.reply(202, {"ok": True, "status": "pending"})


def _handle_stop(req, body, s):
    pc = _pc_id()
    if _online(pc):
        _invoke(pc, "game_stream_stop", {"sunshine": _sunshine_conn()})
    s.set_live({"active": False, "client": None, "app": None})
    return req.reply(200, {"ok": True})


def _handle_pair(req, body, s):
    pc = _pc_id()
    if not _online(pc):
        return req.reply(409, {"ok": False, "error": "The PC is asleep or offline", "offline": True})
    res = _invoke(pc, "game_stream_pair", {"sunshine": _sunshine_conn(),
                  "device": body.get("device"), "pin": body.get("pin")}) or {}
    return req.reply(200, {"ok": bool(res.get("ok", False)), "detail": res.get("detail")})


def _handle_unpair(req, body, s):
    pc = _pc_id()
    if _online(pc):
        _invoke(pc, "game_stream_unpair", {"sunshine": _sunshine_conn(),
                "uuid": body.get("uuid") or body.get("device")})
    return req.reply(200, {"ok": True})


_DESIRED = {"on": None}


def power_changed(on: bool) -> None:
    """The Power switch flipped: remember the desired state and push it to the PC
    (the PC's watcher subsystem starts/stops on it; re-pushed on every bridge resync)."""
    _DESIRED["on"] = bool(on)
    try:
        _publish_to(_pc_id(), "game_stream_power", {"on": bool(on)})
    except Exception:  # noqa: BLE001
        pass


def resync(did: str) -> None:
    if _DESIRED["on"] is not None:
        _publish_to(did, "game_stream_power", {"on": _DESIRED["on"]})


def route(req) -> bool:
    parts = [p for p in req.sub.strip("/").split("/") if p]
    body = req.body if isinstance(req.body, dict) else {}
    s = store()
    if req.method == "GET" and parts == ["status"]:
        return _handle_status(req, s)
    if req.method == "POST" and parts == ["start"]:
        return _handle_start(req, body, s)
    if req.method == "POST" and parts == ["stop"]:
        return _handle_stop(req, body, s)
    if req.method == "POST" and parts == ["pair"]:
        return _handle_pair(req, body, s)
    if req.method == "POST" and parts == ["unpair"]:
        return _handle_unpair(req, body, s)
    if req.method == "POST" and parts == ["event"]:
        _on_event(_pc_id(), body)
        return req.reply(200, {"ok": True})
    if req.method == "GET" and parts == ["settings"]:
        return req.reply(200, {"settings": _public_settings()})
    return False
