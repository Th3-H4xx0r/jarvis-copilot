"""notify_phone — show a visible notification on the user's phone(s).

Fans out an APNs/FCM *alert* push to every mobile device paired with this
server (the JarvisCopilot mobile client and the JarvisWearables app), so an
automation — a door sensor script on an ESP32 board, a scheduled check, a
long task finishing — can reach the user even when no app is open.

Goes through the webui's host-signed loopback (`POST /api/devices/notify`),
the same path the device tools use, because the push registry lives in the
webui process.
"""
from __future__ import annotations

from tools.registry import registry

NOTIFY_PHONE_SCHEMA = {
    "name": "notify_phone",
    "description": (
        "Send a visible push notification to the user's phone (all paired mobile "
        "devices). Use for alerts the user asked to be told about — a sensor "
        "tripped, a job finished, a reminder — not for ordinary replies."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "title": {"type": "string", "description": "Short title, e.g. 'Front door'"},
            "body": {"type": "string", "description": "One or two sentences of detail"},
        },
        "required": ["title"],
    },
}


def notify_phone_tool(args, **kw):
    title = str(args.get("title") or "").strip()
    body = str(args.get("body") or "").strip()
    if not title and not body:
        return {"ok": False, "error": "title or body is required"}
    from tools.chrome_device_tool import _api_request
    res = _api_request("POST", "/api/devices/notify", {"title": title, "body": body}, timeout=15.0)
    if res.get("_error"):
        return {"ok": False, "error": res["_error"]}
    sent = int(res.get("sent") or 0)
    if sent == 0:
        return {"ok": False, "error": "no phone with push registered"}
    return {"ok": True, "sent": sent}


def _check_notify_phone():
    return True


registry.register(
    name="notify_phone",
    toolset="devices",
    schema=NOTIFY_PHONE_SCHEMA,
    handler=notify_phone_tool,
    check_fn=_check_notify_phone,
    emoji="🔔",
)
