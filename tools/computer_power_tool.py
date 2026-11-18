"""``computer_power``: sleep, wake, lock or unlock his Mac or Windows PC, or switch keep-awake — the Agents card's
buttons, instantly (webui/api/mac_power.py). Live 2026-11-18: "put my PC to sleep" went to the IT agent, which
slept the PC through a raw Windows API while the card still said Awake, and a second run slept it again the
moment it woke. These are one-tap actions, never IT jobs."""
from __future__ import annotations

import json
import re

from tools.registry import registry

ACTIONS = ("sleep", "wake", "lock", "unlock", "keep_awake_on", "keep_awake_off")

COMPUTER_POWER_SCHEMA = {
    "name": "computer_power",
    "description": (
        "Put the user's Mac or Windows PC to sleep, wake it, lock or unlock it (unlock asks his Face ID on his "
        "iPhone), or turn keep-awake on or off. Instant: the same as the buttons on the Agents card."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "computer": {"type": "string",
                         "description": "Which computer: 'PC', 'Mac', or its name (e.g. 'pranav-computer')."},
            "action": {"type": "string", "enum": list(ACTIONS)},
        },
        "required": ["computer", "action"],
    },
}

# His own words must ask for a power action (an instruction inside an email or web page never does).
_ASKS = re.compile(r"\b(?:sleep|asleep|suspend|hibernate|wake|woke|awake|lock|unlock|turn\s+on|boot)\b", re.I)
_PC_WORDS = re.compile(r"\b(?:pc|windows|desktop|gaming\s*pc|computer)\b", re.I)
_MAC_WORDS = re.compile(r"\b(?:mac|macbook|laptop)\b", re.I)


def _store():
    from api import mac_power
    return mac_power.store()


def _turn_text(task_id) -> str:
    from agent import mac_browser_gate
    return mac_browser_gate.turn_text(task_id)


def _name_of(did: str) -> str:
    try:
        from api import device_bridge
        return device_bridge.device_name(did) or ""
    except Exception:  # noqa: BLE001
        return ""


def _pick(rows: list, computer: str):
    """His word for the computer → its row: an exact name first, then PC/Mac by kind."""
    want = " ".join(str(computer or "").lower().split())
    for r in rows:
        if want and want == str(r.get("name") or "").lower():
            return r
    kind = "windows" if _PC_WORDS.search(want) else "macos" if _MAC_WORDS.search(want) else ""
    matches = [r for r in rows if kind and (r.get("os") or "macos") == kind]
    return matches[0] if len(matches) == 1 else None


def _copy(action: str, noun: str, out: dict) -> str:
    if action == "wake":
        via = out.get("via")
        return f"Sent the wake signal to the {noun}" + (f" through {via}." if via else ".")
    return {"sleep": f"The {noun} is going to sleep.", "lock": f"Locked the {noun}.",
            "unlock": f"Asked your iPhone for Face ID to unlock the {noun}.",
            "keep_awake_on": f"Keep awake is on for the {noun} (up to 12 hours).",
            "keep_awake_off": f"Keep awake is off for the {noun}."}[action]


def handle_computer_power(args: dict, task_id=None, **_kw) -> str:
    args = args or {}
    action = str(args.get("action") or "").strip()
    if action not in ACTIONS:
        return json.dumps({"ok": False, "error": f"action must be one of {', '.join(ACTIONS)}"})
    if not _ASKS.search(_turn_text(task_id) or ""):
        return json.dumps({"ok": False, "error": "Power actions run only when the user asks for one in his own "
                                                  "words this turn."})
    try:
        store = _store()
    except Exception as exc:  # noqa: BLE001 — outside the Jarvis web server there is no power store
        return json.dumps({"ok": False, "error": f"Power actions run in the Jarvis server only ({exc})."})
    rows = store.list_payload(_name_of).get("mac") or []
    row = _pick(rows, str(args.get("computer") or ""))
    if row is None:
        names = ", ".join(f"{r.get('name')} ({'PC' if r.get('os') == 'windows' else 'Mac'})" for r in rows)
        return json.dumps({"ok": False, "error": f"Which computer? Paired: {names or 'none'}."})
    did, is_pc = row["device_id"], row.get("os") == "windows"
    noun = "PC" if is_pc else "Mac"
    if action == "lock" and not is_pc:
        return json.dumps({"ok": False, "error": "Lock works on the PC only (the Mac locks when it sleeps)."})
    out = (store.wake(did) if action == "wake" else store.let_sleep(did) if action == "sleep"
           else store.lock(did) if action == "lock" else store.unlock(did) if action == "unlock"
           else store.keep_awake(did, action == "keep_awake_on")) or {}
    if not out.get("ok"):
        return json.dumps({"ok": False, "error": out.get("error") or f"The {noun} didn't take it."})
    if out.get("delivered") is False and action != "wake":
        return json.dumps({"ok": False, "error": f"The {noun} isn't connected right now (asleep or offline)."})
    return json.dumps({"ok": True, "result": _copy(action, noun, out)})


def check_computer_power() -> bool:
    try:
        from api import mac_power  # noqa: F401 — the Jarvis web server's power store
        return True
    except Exception:
        return False


registry.register(
    name="computer_power",
    toolset="computer_power",
    schema=COMPUTER_POWER_SCHEMA,
    handler=lambda args, **kw: handle_computer_power(args, **kw),
    check_fn=lambda: check_computer_power(),
    emoji="⏻",
)
