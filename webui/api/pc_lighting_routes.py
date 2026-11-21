"""PC lighting over HTTP (/api/pc-lighting, gated by the PC Lighting Power integration) and the bridge
events the PC sends (pc_lighting_state, pc_specs). The server holds the canonical state and LED map
(api.pc_lighting_store); the PC's jc-client renders them; devices get topic `pc_lighting`.
"""
from __future__ import annotations

import threading
from typing import Any, Callable, Optional

OFFLINE = "The PC is asleep or offline"
OUTDATED = "Update Jarvis on the PC to control its lights"
PROBE_KEYS = ("controller", "zone", "resize", "led", "range", "color", "clear")
SETUP_TIMEOUT = 960.0


# ── seams (tests replace these) ──────────────────────────────────────────────
def store():
    from api.pc_lighting_store import store as _store
    return _store()


def _invoke(did: str, skill: str, args: dict, timeout: float = 15.0) -> dict:
    from api import device_bridge
    return device_bridge.invoke_skill(did, skill, args, timeout=timeout)


def _connected() -> list:
    from api import device_bridge
    return list(device_bridge.connected_device_ids())


def _device_os(did: str) -> str:
    from api import device_bridge
    return device_bridge.device_os(did)


def _publish(topic: str, data: dict) -> None:
    from api import device_bridge
    device_bridge.publish(topic, data)


def _settings() -> dict:
    try:
        from jarvis_power import discovery
        return discovery.get("pc-lighting").read_settings()
    except Exception:  # noqa: BLE001
        return {}


def _enabled() -> bool:
    try:
        from jarvis_power import state
        return state.is_on("pc-lighting")
    except Exception:  # noqa: BLE001
        return True


def _sensor_driver() -> bool:
    try:
        from jarvis_power import discovery
        return discovery.get("pc-stats").read_settings().get("sensor_driver", True) is not False
    except Exception:  # noqa: BLE001
        return True


def _spawn(fn: Callable, *args: Any) -> None:
    threading.Thread(target=fn, args=args, name="pc-lighting-push", daemon=True).start()


# ── helpers ──────────────────────────────────────────────────────────────────
def pc_device_id(requested: str = "") -> str:
    if requested:
        return requested
    for did in _connected():
        try:
            if _device_os(did) == "windows":
                return did
        except Exception:  # noqa: BLE001
            continue
    known = store().devices()
    return known[0] if known else ""


def _online(did: str) -> bool:
    return bool(did) and did in _connected()


def _address() -> str:
    return str(_settings().get("address") or "127.0.0.1:6742")


def payload(did: str) -> dict:
    s = store()
    live = s.live(did)
    return {"device_id": did or None, "online": _online(did), "state": s.state(did), "map": s.map(did),
            "looks": s.looks(did), "setup": s.setup(did), "coverage": s.coverage(did), "address": _address(),
            "live": {k: live.get(k) for k in ("engine", "error", "paused_for_game", "controllers", "at")}}


def publish(did: str) -> None:
    try:
        _publish("pc_lighting", payload(did))
    except Exception:  # noqa: BLE001
        pass


def _result(r: dict) -> tuple[bool, Any]:
    if not r.get("ok"):
        err = str(r.get("error") or "the PC didn't answer")
        return False, OUTDATED if "no skill named" in err else err
    res = r.get("result")
    if isinstance(res, dict) and res.get("ok") is False:
        return False, str(res.get("error") or "the PC refused")
    return True, res


def push_state(did: str, enabled: Optional[bool] = None) -> tuple[bool, Any]:
    st = store().state(did)
    rev = st.pop("rev", 0)
    return _result(_invoke(did, "lighting_state_set", {"state": st, "rev": rev, "address": _address(),
                                                        "enabled": _enabled() if enabled is None else enabled}))


def push_map(did: str) -> tuple[bool, Any]:
    return _result(_invoke(did, "lighting_map_set", {"map": store().map(did)}))


def resync(did: str) -> None:
    push_map(did)
    push_state(did)


def summary() -> dict:
    did = pc_device_id()
    if not did:
        return {"device_id": "", "online": False}
    s = store()
    st = s.state(did)
    return {"device_id": did, "online": _online(did), "mapped": bool(s.map(did).get("segments")),
            "on": st["on"], "effect": st["parts"]["top"]["effect"], "brightness": st["brightness"]}


def power_changed(enabled: bool) -> None:
    """The Power switch moved: tell the PC to start or stop driving the lights."""
    did = pc_device_id()
    if did and _online(did):
        _spawn(push_map, did) if enabled else None
        _spawn(push_state, did, enabled)


# ── bridge events ────────────────────────────────────────────────────────────
def on_state_event(did: str, data: dict) -> None:
    s = store()
    s.set_live(did, {k: data.get(k) for k in ("engine", "error", "paused_for_game", "controllers",
                                              "state_rev", "map_version")})
    st, m = s.state(did), s.map(did)
    if st.get("rev", 0) > 0 or m.get("rev", 0) > 0:
        if data.get("state_rev") != st.get("rev") or data.get("map_version") != m.get("rev"):
            _spawn(resync, did)
    publish(did)


def on_specs_event(did: str, data: dict) -> None:
    if isinstance(data, dict) and data:
        store().set_specs(did, data)
        try:
            _publish("pc_specs", {"device_id": did, "read_at": data.get("read_at")})
        except Exception:  # noqa: BLE001
            pass


def register_events() -> None:
    from api import device_bridge
    device_bridge.on_device_event("pc_lighting_state", on_state_event)
    device_bridge.on_device_event("pc_specs", on_specs_event)


# ── HTTP ─────────────────────────────────────────────────────────────────────
def route(req) -> bool:
    parts = [p for p in req.sub.strip("/").split("/") if p]
    body = req.body if isinstance(req.body, dict) else {}
    q = req.query.get("device_id", [""])[0] if req.method == "GET" else ""
    did = pc_device_id(str(body.get("device_id") or q or ""))
    s = store()

    if req.method == "GET" and parts == []:
        return req.reply(200, payload(did))
    if req.method == "GET" and parts == ["looks"]:
        return req.reply(200, {"looks": s.looks(did)})
    if req.method == "DELETE" and len(parts) == 2 and parts[0] == "looks":
        s.delete_look(did, parts[1])
        publish(did)
        return req.reply(200, {"ok": True, "looks": s.looks(did)})
    if req.method == "POST" and parts == ["looks"]:
        try:
            look = s.save_look(did, str(body.get("name") or ""))
        except ValueError as exc:
            return req.reply(400, {"ok": False, "error": str(exc)})
        publish(did)
        return req.reply(200, {"ok": True, "look": look})

    needs_pc = (req.method == "POST" and parts in (["state"], ["looks", "apply"], ["probe"], ["setup"]))
    if needs_pc and not _online(did):
        return req.reply(409, {"ok": False, "error": OFFLINE, "offline": True})

    if req.method == "POST" and parts == ["state"]:
        partial = {k: body[k] for k in ("part", "effect", "color", "speed", "brightness", "on") if k in body}
        part = partial.get("part", "all")
        host = s.coverage(did).get(part) if part != "all" else None
        try:
            st = s.update_state(did, partial)
            if host and host != "missing":
                st = s.update_state(did, dict(partial, part=host))
        except ValueError as exc:
            return req.reply(400, {"ok": False, "error": str(exc)})
        ok, res = push_state(did)
        publish(did)
        return req.reply(200, {"ok": True, "state": st}) if ok else req.reply(502, {"ok": False, "error": res, "state": st})
    if req.method == "POST" and parts == ["looks", "apply"]:
        try:
            st = s.apply_look(did, str(body.get("name") or ""))
        except KeyError:
            return req.reply(404, {"ok": False, "error": "No look with that name"})
        ok, res = push_state(did)
        publish(did)
        return req.reply(200, {"ok": True, "state": st}) if ok else req.reply(502, {"ok": False, "error": res, "state": st})
    if req.method == "POST" and parts == ["probe"]:
        args = {k: body[k] for k in PROBE_KEYS if k in body}
        ok, res = _result(_invoke(did, "lighting_probe", args))
        return req.reply(200, {"ok": True, "result": res}) if ok else req.reply(502, {"ok": False, "error": res})
    if req.method == "PUT" and parts == ["map"]:
        from api.pc_lighting_store import validate_map
        errors = validate_map(body)
        if errors:
            return req.reply(400, {"ok": False, "errors": errors, "error": errors[0]})
        m = s.set_map(did, body)
        if "missing" not in s.coverage(did).values():
            s.set_setup_step(did, {"id": "calibrate", "state": "done", "detail": "Every part is mapped"})
        if _online(did):
            push_map(did)
        publish(did)
        return req.reply(200, {"ok": True, "map": m, "coverage": s.coverage(did)})
    if req.method == "POST" and parts == ["setup"]:
        step = str(body.get("step") or "")
        ok, res = _result(_invoke(did, "lighting_setup", {"step": step, "sensor_driver": _sensor_driver()},
                                  timeout=SETUP_TIMEOUT))
        if not ok:
            res = {"id": step, "state": "failed", "detail": res}
        s.set_setup_step(did, res)
        if "still_in_games" in res:
            s.update_state(did, {"part": "all", "still_in_games": res["still_in_games"]})
            push_state(did)
        publish(did)
        return req.reply(200, {"ok": True, "step": res})
    return False
