"""Which paired device a chat or voice turn came from.

The agent otherwise can't tell a request typed on the Mac from one spoken to the
Jarvis Pod: "show me a cat" came back as a link, and "directions to Taco Bell"
could open on whichever device offered the skill first. Each turn's entry point
resolves the paired device from the request's session cookie (so a client can't
claim to be another device), then

* ``directive()`` says so in the system text for that one call (the Chats tab
  still shows only what the user said), and
* ``note_turn()`` records it so a ``device_*`` tool called without a ``device``
  argument runs on the device the user is using (``device_for_session``).
"""
from __future__ import annotations

import threading
from typing import Optional

_LOCK = threading.Lock()
_SESSION_DEVICE: dict[str, str] = {}

_KIND_LABEL = {"mobile-ios": "the iPhone app", "desktop": "the Mac app", "browser": "the web app"}


def origin_for_handler(handler) -> Optional[dict]:
    """The paired device behind this request, or None (no cookie, expired, unpaired)."""
    try:
        from api.auth import parse_cookie, verify_session
        from api.pairing import find_device_by_session

        cookie = parse_cookie(handler)
        if not cookie or not verify_session(cookie):
            return None
        device = find_device_by_session(cookie)
    except Exception:
        return None
    if not device or not device.get("id"):
        return None
    return {
        "device_id": str(device["id"]),
        "name": str(device.get("name") or "device").strip() or "device",
        "kind": str(device.get("kind") or "").strip().lower(),
    }


def _skill_names(device_id: str) -> list[str]:
    try:
        from api import device_bridge

        return [str(s.get("name")) for s in device_bridge.skills_for_device(device_id) if s.get("name")]
    except Exception:
        return []


def directive(origin: Optional[dict], channel: str) -> str:
    """System text naming the device this turn came from; "" when unknown."""
    if not origin:
        return ""
    did, name = origin["device_id"], origin["name"]
    how = "by voice" if channel == "voice" else "in chat"
    label = _KIND_LABEL.get(origin.get("kind") or "")
    via = f", {label}" if label else ""
    parts = [f'[Turn context: the user sent this {how} from their device "{name}" (id {did}{via}).']
    skills = _skill_names(did)
    if skills:
        parts.append(
            "Anything to open, show or play — an app, a link, directions, a map, media, a picture, "
            f'a page — goes to this device: when a device_* tool offers a `device` choice, pass device="{did}". '
            "Use another device only when the user names it."
        )
        if any(s.endswith("_show") for s in skills):
            parts.append(
                "This device has a screen: when the user asks to see something (a picture, a chart), "
                "put it on the screen with its show tool — never answer with only a link."
            )
    else:
        parts.append(
            "This device has no device tools, so results belong in the reply itself; "
            "use another device only when the user names it."
        )
    return " ".join(parts) + "]"


def note_turn(session_id: str, origin: Optional[dict]) -> None:
    """Remember the device for ``session_id``'s current turn (None forgets it)."""
    if not session_id:
        return
    with _LOCK:
        if origin:
            _SESSION_DEVICE[session_id] = origin["device_id"]
        else:
            _SESSION_DEVICE.pop(session_id, None)


def device_for_session(session_id: Optional[str]) -> Optional[str]:
    if not session_id:
        return None
    with _LOCK:
        return _SESSION_DEVICE.get(session_id)
