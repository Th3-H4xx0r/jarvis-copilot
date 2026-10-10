"""door_* tools — Jarvis's side of the door alarm (Pranav's PHYSEN Smart Life door-sensor hub).

The alarm lives in the webui process; these tools reach it over the host-signed loopback, so they
work from any process (gateway, cron, kanban). Disarming and silencing never happen from a tool:
they only send a Face ID approval to his iPhone.
"""
from __future__ import annotations

import json
import urllib.parse
from typing import Any

STATUS_SCHEMA = {
    "name": "door_status",
    "description": (
        "Pranav's door alarm (Smart Life door-sensor hub + its door contacts): alarm state "
        "(disarmed / arming / armed_away / armed_home / entry delay / triggered), each door's open or "
        "closed state and when it last opened, the hub's settings and their current values, and "
        "whether the ESP32 at home and Tuya's cloud can see the hub."
    ),
    "parameters": {"type": "object", "properties": {}},
}

ARM_SCHEMA = {
    "name": "door_arm",
    "description": (
        "Arm the door alarm when it is off. mode=away (exit delay, then every door) or home "
        "(immediately, only doors marked active at home). If a watched door is open the server refuses "
        "and names it; arm again with bypass=[that open door's id] only if he says to ignore it. Once "
        "armed, changing the mode or re-arming happens on his iPhone, not here."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "mode": {"type": "string", "enum": ["away", "home"]},
            "bypass": {"type": "array", "items": {"type": "string"}, "description": "Contact ids to ignore this time."},
        },
        "required": ["mode"],
    },
}

DISARM_SCHEMA = {
    "name": "door_disarm",
    "description": (
        "Ask to disarm the door alarm (also stops a siren). It needs Face ID on Pranav's iPhone: this "
        "sends the approval there and returns at once. Tell him to approve it on his phone. Never call "
        "it for anyone else's request."
    ),
    "parameters": {"type": "object", "properties": {}},
}

SILENCE_SCHEMA = {
    "name": "door_silence",
    "description": (
        "Ask to silence the hub's siren while the alarm stays triggered. Needs Face ID on Pranav's "
        "iPhone, like door_disarm."
    ),
    "parameters": {"type": "object", "properties": {}},
}

SET_SCHEMA = {
    "name": "door_set",
    "description": (
        "Change one of the hub's own settings (a data point from door_status 'settings': volume, "
        "ringtone, mode, chime…) while the alarm is off. setting = its code. The hub must confirm it; "
        "an error means it didn't."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "setting": {"type": "string"},
            "value": {"description": "A value door_status lists as allowed (on/off, a choice, or a number)."},
        },
        "required": ["setting", "value"],
    },
}

HISTORY_SCHEMA = {
    "name": "door_history",
    "description": "Recent door alarm history (doors opening/closing, arming, alarms, health), newest first.",
    "parameters": {
        "type": "object",
        "properties": {
            "limit": {"type": "integer", "minimum": 1, "maximum": 200},
            "contact": {"type": "string", "description": "Only this contact id."},
        },
    },
}

SETTINGS_SCHEMA = {
    "name": "door_settings",
    "description": (
        "Read the alarm's own settings (action=get): alarm {exit_delay, entry_delay, siren_duration} "
        "in seconds; contacts {<contact id>: {name, instant, active_home, notify_disarmed, "
        "on_open_prompt}}; siren {ringtone, volume}. action=set can only rename doors "
        "(contacts {<id>: {name}}); everything else changes on his iPhone's Door Alarm page."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["get", "set"]},
            "alarm": {"type": "object"},
            "contacts": {"type": "object"},
            "siren": {"type": "object"},
        },
        "required": ["action"],
    },
}


def available() -> bool:
    try:
        from plugins.door_alarm.store import DoorStore
        return bool(DoorStore().config().get("dev_id"))
    except Exception:
        return False


def _api(method: str, path: str, body: dict | None = None, timeout: float = 15.0) -> dict:
    from tools.chrome_device_tool import _api_request
    return _api_request(method, path, body, timeout=timeout)


def _error(answer: dict, fallback: str) -> str | None:
    if answer.get("_error"):
        return f"Couldn't reach the door alarm: {answer['_error']}"
    if answer.get("ok") is False or answer.get("error"):
        return answer.get("error") or fallback
    return None


def _out(payload: Any) -> str:
    return json.dumps(payload, default=str)


def _handle_status(args: dict, **_: Any) -> str:
    state = _api("GET", "/api/door/state")
    err = _error(state, "Couldn't read the door alarm.")
    if err:
        return _out({"error": err})
    hub = state.get("hub") or {}
    values = hub.get("values") or {}
    settings = []
    for dp in hub.get("dps") or []:
        if not dp.get("writable"):
            continue
        item = {"code": dp["code"], "name": dp.get("name"), "value": (values.get(dp["code"]) or {}).get("value"),
                "type": dp.get("type")}
        if dp.get("type") == "enum":
            item["choices"] = dp.get("range")
        elif dp.get("type") == "value":
            item.update({"min": dp.get("min"), "max": dp.get("max"), "unit": dp.get("unit")})
        settings.append(item)
    link = hub.get("link") or {}
    return _out({
        "setup": state.get("setup"),
        "alarm": state.get("alarm"),
        "hub": hub.get("name"),
        "contacts": [{k: c.get(k) for k in ("id", "name", "open", "last_open", "last_close", "instant", "active_home")}
                     for c in hub.get("contacts") or []],
        "settings": settings,
        "links": {"esp32": bool(link.get("local_alive")), "cloud": bool(link.get("cloud_alive"))},
        "approvals_waiting": len(state.get("approvals") or []),
    })


def _handle_arm(args: dict, **_: Any) -> str:
    body = {"mode": args.get("mode"), "bypass": [str(b) for b in args.get("bypass") or []], "source": "Jarvis"}
    answer = _api("POST", "/api/door/arm", body)
    err = _error(answer, "The door alarm didn't arm.")
    if err:
        out = {"error": err}
        if answer.get("open_contacts"):
            out["open_contacts"] = answer["open_contacts"]
        return _out(out)
    return _out({"ok": True, "alarm": (answer.get("state") or answer).get("alarm")})


def _approval(action: str) -> str:
    answer = _api("POST", "/api/door/approvals", {"action": action})
    err = _error(answer, "Couldn't send the approval to his iPhone.")
    if err:
        return _out({"error": err})
    return _out({"pending_approval": True, "action": action,
                 "message": "Sent to Pranav's iPhone — it happens once he approves it with Face ID "
                            "(within 2 minutes). Tell him to check his phone."})


def _handle_disarm(args: dict, **_: Any) -> str:
    return _approval("disarm")


def _handle_silence(args: dict, **_: Any) -> str:
    return _approval("silence")


def _handle_set(args: dict, **_: Any) -> str:
    answer = _api("POST", "/api/door/set", {"code": str(args.get("setting") or ""), "value": args.get("value")},
                  timeout=20.0)
    err = _error(answer, "The hub didn't take that setting.")
    return _out({"error": err} if err else answer)


def _handle_history(args: dict, **_: Any) -> str:
    query = {"limit": int(args.get("limit") or 30)}
    if args.get("contact"):
        query["contact"] = str(args["contact"])
    answer = _api("GET", "/api/door/history?" + urllib.parse.urlencode(query))
    err = _error(answer, "Couldn't read the door history.")
    return _out({"error": err} if err else answer)


def _handle_settings(args: dict, **_: Any) -> str:
    if args.get("action") == "set":
        body = {k: args[k] for k in ("alarm", "contacts", "siren") if isinstance(args.get(k), dict)}
        answer = _api("POST", "/api/door/settings", body)
    else:
        answer = _api("GET", "/api/door/settings")
    err = _error(answer, "Couldn't change the door alarm settings.")
    return _out({"error": err} if err else answer)


TOOLS = [
    ("door_status", STATUS_SCHEMA, _handle_status, "🚪"),
    ("door_arm", ARM_SCHEMA, _handle_arm, "🛡️"),
    ("door_disarm", DISARM_SCHEMA, _handle_disarm, "🔓"),
    ("door_silence", SILENCE_SCHEMA, _handle_silence, "🔕"),
    ("door_set", SET_SCHEMA, _handle_set, "🎚️"),
    ("door_history", HISTORY_SCHEMA, _handle_history, "📜"),
    ("door_settings", SETTINGS_SCHEMA, _handle_settings, "⚙️"),
]
