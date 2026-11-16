"""Remote Desktop status for Jarvis (toolset ``remote_desktop``, the remote-desktop Power integration).

Read-only: whether his Windows PC is ready for Remote Desktop and who is connected. There is no tool to
start a session — a session always needs his Face ID on the iPhone
(docs/superpowers/specs/2026-11-15-remote-desktop-design.md).
"""
from __future__ import annotations

import json

from tools.chrome_device_tool import _api_request
from tools.registry import registry


def _ready(st: dict) -> tuple[bool, str]:
    if not st.get("pro"):
        return False, f"{st.get('edition') or 'Windows'} can't host Remote Desktop; it needs Windows 11 Pro."
    if not st.get("rdp_enabled") or not st.get("firewall_scoped"):
        return False, "Remote Desktop isn't set up yet: Jarvis on the PC → Settings → PC power → Remote Desktop → Set up."
    if not st.get("has_password"):
        return False, "The Microsoft account password isn't saved in Jarvis on the PC yet."
    return True, "Ready: tap Remote Desktop on the PC's card and approve with Face ID."


def remote_desktop_status(args: dict, **_kw) -> str:
    status = _api_request("GET", "/api/rdp/status")
    if "_error" in status:
        return json.dumps({"ok": False, "error": status["_error"]})
    if status.get("error"):
        return json.dumps({"ok": False, "error": status["error"]})
    sessions = _api_request("GET", "/api/rdp/sessions")
    live = [] if "_error" in sessions else sessions.get("sessions") or []
    devices = []
    for st in status.get("devices") or []:
        ready, why = _ready(st)
        devices.append({"device_id": st.get("device_id"), "edition": st.get("edition"), "ready": ready, "detail": why,
                        "in_use_locally": (st.get("idle_s") or 1e9) < 120 and not st.get("locked"),
                        "game": st.get("game")})
    keep = ("id", "device_id", "client", "state", "created", "last_activity")
    return json.dumps({"ok": True, "devices": devices, "offline": not devices,
                       "sessions": [{k: s.get(k) for k in keep if k in s} for s in live]})


registry.register(
    name="remote_desktop_status", toolset="remote_desktop", emoji="🖥️",
    schema={
        "name": "remote_desktop_status",
        "description": ("Whether his Windows PC is ready for Remote Desktop (edition, setup, saved password), whether "
                        "someone is using it or a game is running, and which Remote Desktop sessions are live. Read-only: "
                        "sessions are started by him from the PC card with Face ID."),
        "parameters": {"type": "object", "properties": {}},
    },
    handler=remote_desktop_status,
)
