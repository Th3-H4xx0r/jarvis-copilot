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
# "PC Stats" (an app) and "MAC address" (a network id) don't name a computer (review).
_SAYS_PC = re.compile(r"\b(?:gaming\s+pc|windows\s+pc|pc(?!\s+stats\b)|(?:on|in|using|with)\s+(?:my\s+)?windows"
                      r"(?!\s+(?:of|on|in)\b))\b", re.I)
_SAYS_MAC = re.compile(r"\bmac(?:book)?\b(?!\s+address(?:es)?\b)", re.I)


def _os_of(row: dict) -> str:
    return str(row.get("device_os") or "macos")


def _meant(rows: list, words: str):
    """The row these words point at: a device name, else "PC"/"Windows" vs "Mac"; (row, kind)."""
    low = str(words or "").lower()
    named = next((o for o in rows if str(o.get("device_name") or "").strip()
                  and str(o.get("device_name")).lower() in low), None)
    if named is not None:
        return named, ""
    # A Mac mention wins: "on my Mac, open the photo of my PC build" is the Mac.
    kind = "macos" if _SAYS_MAC.search(words or "") else "windows" if _SAYS_PC.search(words or "") else ""
    if kind:
        return next((o for o in rows if _os_of(o) == kind), None), kind
    return None, ""


def pick_computer(offers: list, origin, text: str, recent=(), prefer: str = "", sleeping=()) -> tuple:
    """``(row, "")`` for the computer to drive, else ``(None, error)``.

    Pranav's rules ("words win" 2026-11-19; "it needs context so I don't have to say PC or Mac" 2026-11-19): the
    computer the chat model chose from the conversation (``prefer``); else the one his words name (its device name,
    "PC"/"Windows" or "Mac"); else the one his last few turns named (``recent``, newest first); else the turn's own
    computer; else the Mac; else whatever computer is on. ``sleeping`` computers can be meant (they get woken);
    with nothing meant, an awake one is used."""
    offers = list(offers or [])
    known = offers + [s for s in (sleeping or ()) if s.get("device_id") not in {o.get("device_id") for o in offers}]
    if not known:
        return None, ("No computer with computer control is online. Open Jarvis on your Mac or PC "
                      "(jc-client) and make sure it is up to date.")
    for words in [prefer, text, *list(recent or ())]:
        if not str(words or "").strip():
            continue
        hit, kind = _meant(known, words)
        if hit is not None:
            return hit, ""
        if kind:
            return None, f"Your {'PC' if kind == 'windows' else 'Mac'} isn't online with computer control."
    own = next((o for o in offers if origin and o.get("device_id") == origin), None)
    if own is not None:
        return own, ""
    if offers:
        return next((o for o in offers if _os_of(o) == "macos"), offers[0]), ""
    return next((o for o in known if _os_of(o) == "macos"), known[0]), ""


def other_computer(device_id, task_id=None):
    """Another computer than ``device_id`` (awake or asleep) as ``(device_id, name)``, or None."""
    try:
        offers = [s for s in _skills() if isinstance(s, dict) and s.get("name") == LOOK_SKILL and s.get("device_id")]
    except Exception:
        offers = []
    try:
        from agent.computer import wake
        offers += wake.sleeping_computers()
    except Exception:
        pass
    for o in offers:
        if o.get("device_id") != device_id:
            return str(o["device_id"]), str(o.get("device_name") or ("PC" if _os_of(o) == "windows" else "Mac"))
    return None


def find_mac(task_id=None, prefer: str = "") -> tuple:
    """``(device_id, name, None)`` for the computer (offering ``ui_look``, or asleep) that this turn means
    (pick_computer), else ``(None, "", error)``. A sleeping one is returned as is: callers wake it."""
    try:
        offers = [s for s in _skills() if isinstance(s, dict) and s.get("name") == LOOK_SKILL and s.get("device_id")]
    except Exception as exc:
        return None, "", f"could not list devices: {exc}"
    try:
        from agent import mac_browser_gate
        text = mac_browser_gate.turn_text(task_id)
        recent = mac_browser_gate.recent_texts(task_id)
    except Exception:
        text, recent = "", []
    try:
        from agent.computer import wake
        sleeping = wake.sleeping_computers()
    except Exception:
        sleeping = []
    pick, err = pick_computer(offers, _origin(task_id), text, recent=recent, prefer=prefer, sleeping=sleeping)
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


_APPS: dict = {}
_APPS_TTL = 600.0


def installed_apps(device_id: str) -> list:
    """The app names this computer's Start menu / Applications lists (cached 10 minutes); [] when it can't say."""
    import time as _t
    hit = _APPS.get(device_id)
    if hit and _t.time() - hit[0] < _APPS_TTL:
        return hit[1]
    res = _invoke(device_id, "installed_apps", {})
    apps = [str(a) for a in (res.get("apps") or [])] if res.get("ok") else []
    if apps:
        _APPS[device_id] = (_t.time(), apps)
    return apps
