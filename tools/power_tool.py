"""power_list / power_set — Jarvis switching and configuring Power integrations.

Both go to the webui over the host-signed loopback, so the webui knows the change
came from Jarvis: switching a protected integration off, or a setting marked
"ask", becomes a Face ID approval on the iPhone; a setting marked "never" is
refused. Tools never touch the state directly.
"""
from __future__ import annotations

import json

from tools.chrome_device_tool import _api_request
from tools.registry import registry

_HIDDEN = {"surfaces", "links", "native", "has_card", "has_page"}


def _fail(message: str) -> str:
    return json.dumps({"ok": False, "error": message}, ensure_ascii=False)


def power_list(args=None, **_kw) -> str:
    out = _api_request("GET", "/api/power")
    if "_error" in out or "error" in out:
        return _fail(out.get("_error") or out.get("error"))
    rows = [{k: v for k, v in row.items() if k not in _HIDDEN}
            for row in out.get("integrations") or []]
    return json.dumps({"ok": True, "integrations": rows}, ensure_ascii=False)


def power_set(args=None, **_kw) -> str:
    args = args or {}
    integration_id = str(args.get("id") or "").strip()
    if not integration_id:
        return _fail("id is required (see power_list)")
    body: dict = {}
    if args.get("enabled") is not None:
        body["enabled"] = bool(args["enabled"])
    if isinstance(args.get("settings"), dict) and args["settings"]:
        body["settings"] = args["settings"]
    if not body:
        return _fail("give enabled and/or settings")
    body["client"] = "jarvis"
    out = _api_request("POST", f"/api/power/{integration_id}", body)
    if "_error" in out:
        return _fail(out["_error"])
    if out.get("pending"):
        return json.dumps({"ok": False, "waiting": "Waiting for Face ID on your iPhone",
                           "approval": out["pending"].get("id")}, ensure_ascii=False)
    if not out.get("ok"):
        return _fail(out.get("error") or "the change was refused")
    result = {"ok": True, "integration": out.get("row")}
    if body.get("enabled") is True:
        result["note"] = "Its tools are available from your next chat."
    return json.dumps(result, ensure_ascii=False)


_LIST = {
    "name": "power_list",
    "description": (
        "List the Power integrations (built-in features on the Integrations tab: car, "
        "door alarm, dashcam, vault, Jarvis Health, kanban, …) with whether each is on, "
        "its status line and its current settings (secrets show only whether they're set)."
    ),
    "parameters": {"type": "object", "properties": {}},
}

_SET = {
    "name": "power_set",
    "description": (
        "Switch a Power integration on or off, or change its settings. Switching a "
        "protected one off (car, door alarm, vault, security advisor) or changing some "
        "settings waits for Pranav's Face ID on his iPhone; tell him so. Some settings can "
        "only be changed in the app. Switching one on gives you its tools from the next chat."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "id": {"type": "string", "description": "The integration id from power_list"},
            "enabled": {"type": "boolean"},
            "settings": {"type": "object", "description": "{setting key: new value}"},
        },
        "required": ["id"],
    },
}

registry.register(name="power_list", toolset="power", schema=_LIST,
                  handler=lambda args, **kw: power_list(args, **kw), emoji="⚡")
registry.register(name="power_set", toolset="power", schema=_SET,
                  handler=lambda args, **kw: power_set(args, **kw), emoji="⚡")
