"""jc-client's ``ui_look`` / ``ui_do`` skills, reached over the device bridge.

In the web UI process the bridge is in memory; elsewhere (the messaging gateway,
the scheduler) the same calls go through the web UI's REST API. Every call
returns a plain dict: the skill's own result, or ``{"ok": False, "error", "device":
True}`` when the Mac itself could not be reached.
"""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)

LOOK_SKILL = "ui_look"
DO_SKILL = "ui_do"
TIMEOUT = 12.0


def _bridge():
    try:
        from api import device_bridge
        if device_bridge.in_process_available():
            return device_bridge
    except Exception:
        pass
    return None


def _skills() -> list[dict]:
    bridge = _bridge()
    if bridge is not None:
        return bridge.all_device_skills()
    from tools.chrome_device_tool import _api_request
    data = _api_request("GET", "/api/devices/skills", timeout=5.0)
    return list((data or {}).get("skills") or []) if isinstance(data, dict) else []


def _origin(task_id):
    try:
        from api import turn_origin
        return turn_origin.device_for_session(task_id)
    except Exception:
        return None


def find_mac(task_id=None) -> tuple:
    """``(device_id, name, None)`` for a reachable device offering ``ui_look`` (the
    turn's own device first), else ``(None, "", error)``."""
    try:
        offers = [s for s in _skills() if isinstance(s, dict) and s.get("name") == LOOK_SKILL and s.get("device_id")]
    except Exception as exc:
        return None, "", f"could not list devices: {exc}"
    if not offers:
        return None, "", ("No Mac with computer control is online. Open the JarvisCopilot Mac app "
                          "(jc-client) and make sure it is up to date.")
    origin = _origin(task_id)
    pick = next((s for s in offers if s["device_id"] == origin), offers[0])
    return str(pick["device_id"]), str(pick.get("device_name") or "Mac"), None


def _invoke(device_id: str, skill: str, args: dict) -> dict:
    try:
        bridge = _bridge()
        if bridge is not None:
            res = bridge.invoke_skill(device_id, skill, args, timeout=TIMEOUT)
        else:
            from tools.chrome_device_tool import _api_request
            res = _api_request("POST", "/api/devices/skills/invoke",
                               body={"device_id": device_id, "skill": skill, "args": args, "timeout": TIMEOUT},
                               timeout=TIMEOUT + 5)
            if isinstance(res, dict) and res.get("_error"):
                res = {"ok": False, "error": res["_error"]}
    except Exception as exc:
        res = {"ok": False, "error": str(exc)}
    if not isinstance(res, dict) or not res.get("ok"):
        err = (res or {}).get("error") if isinstance(res, dict) else None
        return {"ok": False, "error": str(err or "the Mac did not answer"), "device": True}
    inner = res.get("result")
    if not isinstance(inner, dict):
        return {"ok": False, "error": "the Mac sent an unexpected reply"}
    if inner.get("ok") is False:
        return {"ok": False, "error": str(inner.get("error") or "failed")}
    return {"ok": True, **inner}


def look(device_id: str, app: str | None = None) -> dict:
    args = {"app": app} if app else {}
    return _invoke(device_id, LOOK_SKILL, args)


def act(device_id: str, action: dict, look_id: str | None) -> dict:
    args = dict(action)
    if look_id:
        args["look_id"] = look_id
    return _invoke(device_id, DO_SKILL, args)
