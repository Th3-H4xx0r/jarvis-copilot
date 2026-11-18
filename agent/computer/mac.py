"""jc-client's ``ui_look`` / ``ui_do`` skills, reached over the device bridge.

In the web UI process the bridge is in memory; elsewhere (the messaging gateway,
the scheduler) the same calls go through the web UI's REST API. Every call
returns a plain dict: the skill's own result, or ``{"ok": False, "error", "device":
True}`` when the Mac itself could not be reached.
"""
from __future__ import annotations

import logging
import re

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


# "the PC", "my gaming PC", "on Windows" — never the plural "windows" (Chrome windows on a Mac).
_SAYS_PC = re.compile(r"\b(?:gaming\s+pc|windows\s+pc|pc|(?:on|in|using|with)\s+(?:my\s+)?windows(?!\s+(?:of|on|in)\b))\b", re.I)
_SAYS_MAC = re.compile(r"\bmac(?:book)?\b", re.I)


def _os_of(row: dict) -> str:
    return str(row.get("device_os") or "macos")


def pick_computer(offers: list, origin, text: str) -> tuple:
    """``(row, "")`` for the computer to drive, else ``(None, error)``.

    Pranav's rule (2026-11-15): the turn's own computer first; then the one the words name
    (its device name, "PC"/"Windows" or "Mac"); else the Mac; else whatever computer is on."""
    if not offers:
        return None, ("No computer with computer control is online. Open Jarvis on your Mac or PC "
                      "(jc-client) and make sure it is up to date.")
    own = next((o for o in offers if origin and o.get("device_id") == origin), None)
    if own is not None:
        return own, ""
    words = str(text or "")
    low = words.lower()
    named = next((o for o in offers if str(o.get("device_name") or "").strip()
                  and str(o.get("device_name")).lower() in low), None)
    if named is not None:
        return named, ""
    # A Mac mention wins: "on my Mac, open the photo of my PC build" is the Mac.
    wants = "macos" if _SAYS_MAC.search(words) else "windows" if _SAYS_PC.search(words) else ""
    if wants:
        hit = next((o for o in offers if _os_of(o) == wants), None)
        if hit is None:
            return None, f"Your {'PC' if wants == 'windows' else 'Mac'} isn't online with computer control."
        return hit, ""
    return next((o for o in offers if _os_of(o) == "macos"), offers[0]), ""


def find_mac(task_id=None) -> tuple:
    """``(device_id, name, None)`` for the computer offering ``ui_look`` that this turn
    means (pick_computer), else ``(None, "", error)``."""
    try:
        offers = [s for s in _skills() if isinstance(s, dict) and s.get("name") == LOOK_SKILL and s.get("device_id")]
    except Exception as exc:
        return None, "", f"could not list devices: {exc}"
    try:
        from agent import mac_browser_gate
        text = mac_browser_gate.turn_text(task_id)
    except Exception:
        text = ""
    pick, err = pick_computer(offers, _origin(task_id), text)
    if pick is None:
        return None, "", err
    fallback = "PC" if _os_of(pick) == "windows" else "Mac"
    return str(pick["device_id"]), str(pick.get("device_name") or fallback), None


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
        # A batch that stopped part way says how many it pressed; a refused move says it didn't land.
        return {"ok": False, "error": str(inner.get("error") or "failed"),
                **{k: inner[k] for k in ("done", "landed") if k in inner}}
    return {"ok": True, **inner}


def supports(device_id: str, skill: str, feature: str) -> bool:
    """Whether this device's jc-client takes a newer look/move argument (old clients reject unknown
    args): "surface" on ui_look, "clicks" on ui_do."""
    try:
        row = next((r for r in _skills() if r.get("device_id") == device_id and r.get("name") == skill), None)
    except Exception:
        return False
    props = ((row or {}).get("input_schema") or {}).get("properties") or {}
    if feature == "clicks":
        return "clicks" in ((props.get("action") or {}).get("enum") or [])
    return feature in props


def os_of(device_id: str) -> str:
    """"windows" or "macos" for a computer (from its advertised skills; "macos" when unknown)."""
    try:
        row = next((r for r in _skills() if r.get("device_id") == device_id), None)
    except Exception:
        return "macos"
    return _os_of(row or {})


def surface_kinds(device_id: str) -> list:
    """The surfaces this device's ui_look can read (empty for an old client)."""
    try:
        row = next((r for r in _skills() if r.get("device_id") == device_id and r.get("name") == LOOK_SKILL), None)
    except Exception:
        return []
    return list(((((row or {}).get("input_schema") or {}).get("properties") or {}).get("surface") or {}).get("enum")
                or [])


def look(device_id: str, app: str | None = None, surface: str | None = None) -> dict:
    args = {"app": app} if app else {}
    if surface:
        args["surface"] = surface
    return _invoke(device_id, LOOK_SKILL, args)


def act(device_id: str, action: dict, look_id: str | None) -> dict:
    args = dict(action)
    if look_id:
        args["look_id"] = look_id
    return _invoke(device_id, DO_SKILL, args)
