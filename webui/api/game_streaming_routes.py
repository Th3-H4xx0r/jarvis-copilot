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

import json
import time
from typing import Any

_PENDING: list[dict] = []
_clock = time.time
# Reads (status / detect / pending pairings) are local Sunshine calls on the PC: answer
# well inside the app's request timeout so a stuck PC never leaves a spinner running.
_READ_TIMEOUT = 10.0


# ── seams (tests replace these) ──────────────────────────────────────────────
def store():
    from api.game_streaming_store import store as _store
    return _store()


def _invoke(did: str, skill: str, args: dict, timeout: float = 20.0) -> dict:
    from api import device_bridge
    # device_bridge wraps the skill's return as {"ok": <transport>, "result": <skill return>};
    # unwrap to the skill's own dict. A transport failure ({"ok": False, "error": ...}, e.g.
    # the device is offline or its jc-client predates the skill) comes back as the skill
    # shape {"ok": False, "detail": <error>}; a missing result degrades to {}.
    env = device_bridge.invoke_skill(did, skill, args, timeout=timeout) or {}
    result = env.get("result")
    if result:
        return result
    if env.get("ok") is False and env.get("error"):
        return {"ok": False, "detail": str(env["error"])}
    return {}


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


def _moonlight_host() -> str:
    """The address a Moonlight client (Mac / iPhone / Android TV) uses to reach the
    gaming PC. Auto-filled from the PC's known address (kept internally from PC setup);
    the user never types it on the setup page. Blank is fine on a LAN where Moonlight
    discovers the host itself; an Android TV carries its own adb address instead."""
    return str(_settings().get("host") or "").strip()


def _migrate_legacy_targets(raw) -> list:
    """Turn the old raw `targets` JSON setting into structured rows (lossless: keeps
    each target's host + tv_addr). Returns [] when there's nothing to migrate."""
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except Exception:  # noqa: BLE001
            return []
    if not isinstance(raw, list):
        return []
    out = []
    for t in raw:
        if not isinstance(t, dict):
            continue
        name = str(t.get("name") or "").strip()
        if not name:
            continue
        row = {"name": name, "kind": str(t.get("kind") or "")}
        if t.get("host"):
            row["host"] = str(t["host"])
        if t.get("tv_addr"):
            row["tv_addr"] = str(t["tv_addr"])
        out.append(row)
    return out


def _targets() -> list:
    """Target devices as the UI, tools and connect-dispatch see them: structured rows
    from the store, with the Moonlight host auto-filled. Migrates any legacy JSON
    `targets` setting into the store once, the first time the store is empty."""
    s = store()
    rows = s.get_targets()
    if not rows:
        migrated = _migrate_legacy_targets(_settings().get("targets"))
        if migrated:
            s.set_targets(migrated)
            rows = s.get_targets()
    host = _moonlight_host()
    out = []
    for t in rows:
        d = {"name": t.get("name"), "kind": t.get("kind") or ""}
        d["host"] = t.get("host") or host
        if t.get("tv_addr"):
            d["tv_addr"] = t["tv_addr"]
        out.append(d)
    return out


def _sunshine_conn() -> dict:
    # jc-client reaches Sunshine on the PC itself, so host/port are always localhost
    # (the PC skill defaults them). The user only sets the Sunshine username + password.
    s = _settings()
    return {"user": s.get("user", ""), "password": s.get("password", ""),
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
        return ""   # the Mac isn't connected
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
    if not did:
        label = "the Mac" if kind == "mac" else f"the {kind}"
        return {"ok": False, "detail": f"{label} is offline"}
    return _invoke(did, "game_stream_connect",
                   {"target": target, "app": app, "stream_running_session": srs}) or {"ok": False}


def complete_pending(pc: str) -> None:
    """Finish pending connects for a now-awake PC; silently drop any past their deadline
    so a stale 'stream X' never fires hours later."""
    now = _clock()
    for p in [p for p in _PENDING if p.get("pc") == pc]:
        try:
            if p.get("deadline", 0) > now:
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
    device_bridge.on_subscribe(_on_subscribe)


# ── HTTP ─────────────────────────────────────────────────────────────────────
def _public_settings() -> dict:
    s = dict(_settings())
    s.pop("password", None)
    return s


def _handle_status(req, s):
    pc = _pc_id()
    if not _online(pc):
        return req.reply(200, {"ok": True, "reachable": False, "needs_login": False,
                               "live": s.get_live(), "paired": s.get_paired(),
                               "apps": [], "targets": _targets()})
    res = _invoke(pc, "game_stream_status", {"sunshine": _sunshine_conn()},
                  timeout=_READ_TIMEOUT) or {}
    data = res.get("data") or {}
    try:
        from api import game_streaming_alerts
        game_streaming_alerts.note_reachable(bool(data.get("reachable", False)))
    except Exception:  # noqa: BLE001
        pass
    if data.get("paired"):
        s.upsert_paired(data["paired"])
    return req.reply(200, {"ok": True, "reachable": bool(data.get("reachable", False)),
                           "needs_login": bool(data.get("needs_login", False)),
                           "live": s.get_live(), "paired": s.get_paired(),
                           "apps": data.get("apps", []), "targets": _targets()})


def _handle_detect(req):
    """Front the PC's Sunshine detect probe for the setup page. When the PC is offline
    we can't probe, so we say so; otherwise {running, needs_login} distinguishes
    "not running" from "running but the login is missing/wrong"."""
    pc = _pc_id()
    if not _online(pc):
        return req.reply(200, {"ok": True, "online": False, "running": False,
                               "needs_login": False, "username": ""})
    log_path = str(_settings().get("log_path") or "").strip()
    res = _invoke(pc, "game_stream_detect",
                  {"sunshine": _sunshine_conn(), "log_path": log_path},
                  timeout=_READ_TIMEOUT) or {}
    data = res.get("data") or {}
    return req.reply(200, {"ok": True, "online": True,
                           "running": bool(data.get("running", False)),
                           "needs_login": bool(data.get("needs_login", False)),
                           "username": str(data.get("username") or "")})


def _handle_set_targets(req, body, s):
    """Write the structured target list the setup page builds (device name + kind, plus
    an Android TV's adb address). No JSON, no per-device host — the Moonlight host is
    auto-filled server-side. Rows without a name are dropped."""
    raw = body.get("targets")
    if not isinstance(raw, list):
        return req.reply(400, {"ok": False, "error": "targets must be a list"})
    clean = []
    for t in raw:
        if not isinstance(t, dict):
            continue
        name = str(t.get("name") or "").strip()
        if not name:
            continue
        row = {"name": name, "kind": str(t.get("kind") or "")}
        addr = str(t.get("tv_addr") or "").strip()
        if addr:
            row["tv_addr"] = addr
        clean.append(row)
    s.set_targets(clean)
    return req.reply(200, {"ok": True, "targets": _targets()})


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


_OFFLINE = {"ok": False, "error": "The PC is asleep or offline", "offline": True}
_OUTDATED = "Your PC's Jarvis client is out of date — update it to pair from here"


def _friendly_detail(detail) -> str | None:
    """A PC transport error, in words: a jc-client without the skill means "update it"."""
    if not detail:
        return None
    text = str(detail)
    return _OUTDATED if "no skill named" in text else text


def _handle_pairings(req):
    """The Moonlight devices waiting to pair (Sunshine's GET /api/pin, via the PC). The
    pair sheet polls this every 2 s while open. 409 while the PC is asleep/offline."""
    pc = _pc_id()
    if not _online(pc):
        return req.reply(409, dict(_OFFLINE, pairings=[]))
    res = _invoke(pc, "game_stream_pending", {"sunshine": _sunshine_conn()},
                  timeout=_READ_TIMEOUT) or {}
    data = res.get("data") or {}
    out = {"ok": bool(res.get("ok", False)),
           "pairings": [p for p in (data.get("pairings") or []) if isinstance(p, dict)],
           "needs_login": bool(data.get("needs_login", False)),
           "reachable": bool(data.get("reachable", res.get("ok", False)))}
    detail = _friendly_detail(res.get("detail"))
    if detail:
        out["detail"] = detail
    return req.reply(200, out)


def _handle_pair(req, body, s):
    pc = _pc_id()
    if not _online(pc):
        return req.reply(409, dict(_OFFLINE))
    args = {"sunshine": _sunshine_conn(), "device": body.get("device"), "pin": body.get("pin")}
    if body.get("pairing_id"):
        args["pairing_id"] = str(body["pairing_id"])
    res = _invoke(pc, "game_stream_pair", args) or {}
    out = {"ok": bool(res.get("ok", False)),
           "detail": _friendly_detail(res.get("detail"))
           or (None if res.get("ok") else "The PC didn't answer — try again")}
    if isinstance(res.get("pairings"), list):
        out["pairings"] = res["pairings"]
    return req.reply(200, out)


def _create_job(**kw):
    from cron.jobs import create_job
    return create_job(**kw)


def schedule_stream(when, target, game):
    tname = target.get("name") if isinstance(target, dict) else str(target or "")
    prompt = f"Stream {game} to {tname} now using the game_stream_start tool."
    return _create_job(prompt=prompt, schedule=str(when or ""),
                       name=f"Stream {game} \u2192 {tname}",
                       integration="game-streaming",
                       enabled_toolsets=["game_streaming"])


def _handle_schedule(req, body):
    job = schedule_stream(body.get("when"), body.get("target"),
                          body.get("game") or body.get("app") or "")
    return req.reply(200, {"ok": True, "job": job})


def _handle_unpair(req, body, s):
    pc = _pc_id()
    if _online(pc):
        _invoke(pc, "game_stream_unpair", {"sunshine": _sunshine_conn(),
                "uuid": body.get("uuid") or body.get("device")})
    return req.reply(200, {"ok": True})


_DESIRED = {"on": None}


def _desired_on() -> bool:
    """The watcher's wanted state: the last power_changed, or — in a fresh webui process
    that hasn't seen one yet — the Power switch itself."""
    if _DESIRED["on"] is not None:
        return bool(_DESIRED["on"])
    return bool(_enabled())


def _power_payload() -> dict:
    """What the PC needs to start its Sunshine-log watcher: the desired on/off, plus
    (when on) the Sunshine connection and the log path to tail. Omits credentials when
    off — the PC only needs to know to stop."""
    on = _desired_on()
    data: dict = {"on": on}
    if on:
        data["sunshine"] = _sunshine_conn()
        log_path = str(_settings().get("log_path") or "").strip()
        if log_path:
            data["log_path"] = log_path
    return data


def power_changed(on: bool) -> None:
    """The Power switch flipped: remember the desired state and push it to the PC
    (the PC's watcher subsystem starts/stops on it; re-pushed on every bridge resync)."""
    _DESIRED["on"] = bool(on)
    try:
        _publish_to(_pc_id(), "game_stream_power", _power_payload())
    except Exception:  # noqa: BLE001
        pass


def resync(did: str) -> None:
    """A (re)connecting PC: re-push the desired power state (with the Sunshine conn +
    log path) so its watcher is started or stopped to match."""
    _publish_to(did, "game_stream_power", _power_payload())


def _on_subscribe(device_id: str, topics) -> None:
    """Re-push the power state once the PC's subscription is stored — race-free, unlike the
    hello that can arrive before the subscribe frame (that push was dropped and the watcher
    never restarted after a reconnect or a wake from sleep)."""
    if "game_stream_power" in (topics or {}):
        resync(device_id)


def route(req) -> bool:
    parts = [p for p in req.sub.strip("/").split("/") if p]
    body = req.body if isinstance(req.body, dict) else {}
    s = store()
    if req.method == "GET" and parts == ["status"]:
        return _handle_status(req, s)
    if req.method == "GET" and parts == ["detect"]:
        return _handle_detect(req)
    if req.method == "GET" and parts == ["pairings"]:
        return _handle_pairings(req)
    if req.method == "POST" and parts == ["targets"]:
        return _handle_set_targets(req, body, s)
    if req.method == "POST" and parts == ["start"]:
        return _handle_start(req, body, s)
    if req.method == "POST" and parts == ["stop"]:
        return _handle_stop(req, body, s)
    if req.method == "POST" and parts == ["pair"]:
        return _handle_pair(req, body, s)
    if req.method == "POST" and parts == ["unpair"]:
        return _handle_unpair(req, body, s)
    if req.method == "POST" and parts == ["schedule"]:
        return _handle_schedule(req, body)
    if req.method == "POST" and parts == ["event"]:
        _on_event(_pc_id(), body)
        return req.reply(200, {"ok": True})
    if req.method == "GET" and parts == ["settings"]:
        return req.reply(200, {"settings": _public_settings()})
    return False
