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
_SESSION_KIND: dict[str, str] = {}
_SESSION_NAME: dict[str, str] = {}

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
    skills = _skill_names(did)
    # Said plainly first: the device he is on right now, by the name it's
    # registered under with Jarvis — never a guess from its kind.
    parts = [f'[Turn context: the user is talking to you {how} from their device "{name}" (id {did}).']
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
        if "ui_look" in skills:
            parts.append(
                "This is the user's Mac and you can see its screen: when they ask about what's on it "
                "(\"this\", \"here\", \"what am I looking at\", an error, a page), look first with the device_ui_look "
                "tool instead of asking them to describe it."
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
            _SESSION_KIND[session_id] = origin.get("kind") or ""
            _SESSION_NAME[session_id] = origin.get("name") or ""
        else:
            _SESSION_DEVICE.pop(session_id, None)
            _SESSION_KIND.pop(session_id, None)
            _SESSION_NAME.pop(session_id, None)


def origin_for_session(session_id: Optional[str]) -> Optional[dict]:
    """The device ``session_id``'s current turn came from — id, name, kind and
    whether it is the user's Mac — or None when it isn't known."""
    device = device_for_session(session_id)
    if not device:
        return None
    with _LOCK:
        name = _SESSION_NAME.get(session_id or "", "")
    return {"device_id": device, "name": name, "kind": kind_for_session(session_id),
            "mac": is_mac_session(session_id)}


def device_for_session(session_id: Optional[str]) -> Optional[str]:
    if not session_id:
        return None
    with _LOCK:
        return _SESSION_DEVICE.get(session_id)


def is_mac_session(session_id: Optional[str]) -> bool:
    """Whether this turn came from the user's Mac: the Mac app, or a device that
    can see the Mac's screen (jc-client, paired as kind "browser", offers ui_look —
    its push to talk is the Mac talking)."""
    if kind_for_session(session_id) == "desktop":
        return True
    device = device_for_session(session_id)
    return bool(device) and "ui_look" in _skill_names(device)


def kind_for_session(session_id: Optional[str]) -> str:
    """The kind of device this turn came from ("desktop" = the Mac app), or ""."""
    if not session_id:
        return ""
    with _LOCK:
        return _SESSION_KIND.get(session_id, "")
