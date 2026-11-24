"""``computer_power``: sleep, wake, lock or unlock his Mac or Windows PC, or switch keep-awake — the Agents card's
buttons, instantly (webui/api/mac_power.py). Live 2026-11-18: "put my PC to sleep" went to the IT agent, which
slept the PC through a raw Windows API while the card still said Awake, and a second run slept it again the
moment it woke. These are one-tap actions, never IT jobs."""
from __future__ import annotations

import json
import re

from tools.registry import registry

ACTIONS = ("sleep", "wake", "lock", "unlock", "keep_awake_on", "keep_awake_off",
           "restart", "shutdown", "force_restart", "force_off")
_FORCE_ACTIONS = frozenset({"force_restart", "force_off"})

COMPUTER_POWER_SCHEMA = {
    "name": "computer_power",
    "description": (
        "Put the user's Mac or Windows PC to sleep, wake it, lock or unlock it (unlock asks his Face ID on his "
        "iPhone), or turn keep-awake on or off — the Agents card's buttons. Wake returns once the computer is up "
        "and ready (up to 2 minutes), so the next step can use it right away; it also turns on a PC that is shut "
        "down. The PC also has restart and shutdown (clean, through Windows) and force_restart / force_off "
        "(its real reset / power button, for a frozen PC: only when he says force or frozen; asks his Face ID)."
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
# Restart / shutdown / force need their own words (review: "wake my PC and read my email" with an email saying
# "shut down the computer" must not shut it down).
_ACTION_WORDS = {
    "restart": re.compile(r"\b(?:restart|reboot)\b", re.I),
    "shutdown": re.compile(r"\b(?:shut\s*down|power\s*off|turn\s+off)\b", re.I),
    "force_restart": re.compile(r"\b(?:restart|reboot|reset|force)\b", re.I),
    "force_off": re.compile(r"\b(?:shut\s*down|power\s*off|turn\s+off|force)\b", re.I),
}
# Force restart / force off cut power (unsaved work is lost): only when he says force or that it's stuck.
_FORCE = re.compile(r"\b(?:force|forced|frozen|freezes|stuck|hung|hangs|not\s+responding|unresponsive)\b", re.I)
_PC_WORDS = re.compile(r"\b(?:pc|windows|desktop|gaming\s*pc|computer)\b", re.I)
_MAC_WORDS = re.compile(r"\b(?:mac|macbook|laptop)\b", re.I)


# computer_do → here: a power request worded at the computer itself (live 2026-11-23: "Can you shut down my PC
# now?" by voice went to computer_do, which drove the PC's screen and tried to open Terminal).
_TARGET = r"(?:the\s+|my\s+|your\s+|this\s+)?(?:windows\s+|gaming\s+)?(?P<obj>pc|computer|desktop|macbook|mac)\b"
_INTENTS = (
    ("shutdown", re.compile(r"\b(?:shut\s*down|power\s*(?:off|down)|turn\s*off)\s+" + _TARGET, re.I)),
    ("shutdown", re.compile(r"\b(?:shut|power|turn)\s+" + _TARGET + r"\s+(?:down|off)\b", re.I)),
    ("restart", re.compile(r"\b(?:restart|reboot)\s+" + _TARGET, re.I)),
    ("sleep", re.compile(r"\bput\s+" + _TARGET + r"\s+to\s+sleep\b", re.I)),
    ("sleep", re.compile(r"\bsleep\s+" + _TARGET, re.I)),
    ("lock", re.compile(r"\block\s+" + _TARGET, re.I)),
    ("wake", re.compile(r"\b(?:turn\s*on|wake(?:\s*up)?|boot(?:\s*up)?|start(?:\s*up)?|power\s*(?:on|up))\s+" + _TARGET,
                        re.I)),
    ("wake", re.compile(r"\b(?:turn|wake|boot|start|power)\s+" + _TARGET + r"\s+(?:on|up)\b", re.I)),
)
# Words around a wake that ask for nothing more ("can you turn on my PC now?").
_FILLER = frozenset("can could would will you please now right away jarvis hey sir for me just quickly go ahead and "
                    "then up it".split())
_NOT = re.compile(r"\b(?:don'?t|do\s+not|never|without|instead\s+of)\b", re.I)


def _intent(text):
    """(action, kind, match) for the first power request in the words, else None."""
    text = str(text or "")
    if _NOT.search(text):
        return None
    for action, rx in _INTENTS:
        m = rx.search(text)
        if m:
            obj = m.group("obj").lower()
            kind = "mac" if obj.startswith("mac") else "computer" if obj == "computer" else "pc"
            if action in ("restart", "shutdown") and _FORCE.search(text):
                action = "force_restart" if action == "restart" else "force_off"
            return action, kind, m
    return None


def power_intent(text):
    """(action, 'pc' | 'mac' | 'computer') when the words ask for a power action on the computer itself, else None."""
    found = _intent(text)
    return found[:2] if found else None


def _only_that(text, m) -> bool:
    """Nothing asked beyond the matched power request."""
    rest = f"{text[:m.start()]} {text[m.end():]}"
    return all(w in _FILLER for w in re.findall(r"[a-z']+", rest.lower()))


def hand_over(goal, computer, task_id, chat_os):
    """computer_do's power requests come here (its result), or None to let the fast hands do it. chat_os() is
    the chat's computer ("windows" / "macos"), asked only for a bare "my computer"."""
    found = _intent(goal)
    if not found:
        return None
    action, kind, m = found
    if kind == "computer":
        want = str(computer or "")
        kind = ("mac" if _MAC_WORDS.search(want) else "pc" if _PC_WORDS.search(want)
                else "mac" if chat_os() == "macos" else "pc")
    if kind == "mac" and action != "sleep":
        return None   # the Mac's restart / shutdown / lock aren't this tool's
    out = handle_computer_power({"computer": "Mac" if kind == "mac" else "PC", "action": action}, task_id=task_id)
    if action == "wake" and not _only_that(str(goal), m):
        # "turn on my PC and launch Warzone": the PC is up now, so the fast hands do the rest; a failed wake stops
        # here with its reason instead of clicking on nothing.
        try:
            ok = bool(json.loads(out).get("ok"))
        except ValueError:
            ok = False
        return None if ok else out
    return out


def _store():
    from api import mac_power
    return mac_power.store()


def _turn_text(task_id) -> str:
    from agent import mac_browser_gate
    return mac_browser_gate.turn_text(task_id)


def _ensure_awake(did: str) -> tuple:
    """Turn it on like a person: wake it, wait for it, sign in (unlock) so it's ready to use."""
    from agent.computer import wake
    ok, note = wake.ensure_awake(did)
    if not ok:
        return ok, note
    ok2, note2 = wake.ensure_unlocked(did)
    if not ok2:
        return True, f"{note} {note2}".strip()   # awake; the unlock waits for him
    return True, " ".join(x for x in (note, note2) if x)


def _ensure_unlocked(did: str) -> tuple:
    from agent.computer import wake
    return wake.ensure_unlocked(did)


def _force_request(did: str, action: str) -> dict:
    """A Face ID request on his iPhone (api/pc_power.py): Jarvis never forces it by itself."""
    from api import pc_power
    return pc_power.create_force_request(did, action, "Jarvis")


# Waking (or keeping awake) can't hurt: no own-words check (live 2026-11-19: "Launch it now." was refused a wake
# and the turn gave up). Sleeping, locking and unlocking still need his own words.
_ANY_TURN = frozenset({"wake", "keep_awake_on"})


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
        if out.get("pending"):
            return (f"Nothing awake could reach the {noun} right now; {via or 'it'} picks up the wake request "
                    f"within {out.get('within_min') or 15} minutes.")
        return f"Sent the wake signal to the {noun}" + (f" through {via}." if via else ".")
    return {"sleep": f"The {noun} is going to sleep.", "lock": f"Locked the {noun}.",
            "restart": f"The {noun} is restarting.", "shutdown": f"The {noun} is shutting down.",
            "unlock": f"Asked your iPhone for Face ID to unlock the {noun}.",
            "keep_awake_on": f"Keep awake is on for the {noun} (up to 12 hours).",
            "keep_awake_off": f"Keep awake is off for the {noun}."}[action]


def handle_computer_power(args: dict, task_id=None, **_kw) -> str:
    args = args or {}
    action = str(args.get("action") or "").strip()
    if action not in ACTIONS:
        return json.dumps({"ok": False, "error": f"action must be one of {', '.join(ACTIONS)}"})
    if action not in _ANY_TURN and not _ACTION_WORDS.get(action, _ASKS).search(_turn_text(task_id) or ""):
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
    if action in ("restart", "shutdown") or action in _FORCE_ACTIONS:
        if not is_pc:
            return json.dumps({"ok": False, "error": "Restart, shutdown and force actions work on the PC only."})
    if action in _FORCE_ACTIONS:
        if not _FORCE.search(_turn_text(task_id) or ""):
            clean = "restart" if action == "force_restart" else "shutdown"
            return json.dumps({"ok": False, "error": f"Force actions cut power and lose unsaved work: use them only when "
                                                      f"he says force or the PC is frozen. For a normal one use {clean}."})
        out = _force_request(did, action) or {}
        if not out.get("ok"):
            return json.dumps({"ok": False, "error": out.get("error") or "Couldn't ask for Face ID."})
        what = "force restart" if action == "force_restart" else "force off"
        return json.dumps({"ok": True, "result": f"Asked your iPhone for Face ID to {what} the {noun}. "
                                                 "It happens once he approves."})
    if action == "wake":
        # Like a person: turn it on and wait until it's ready, so the next step can use it. A PC lit by its
        # power button whose Jarvis client isn't back yet ("starting") still needs the wait.
        if row.get("state") == "awake" and row.get("reason") != "starting":
            return json.dumps({"ok": True, "result": f"The {noun} is already awake."})
        ok, note = _ensure_awake(did)
        return json.dumps({"ok": True, "result": note or f"The {noun} is awake."} if ok else {"ok": False, "error": note})
    if action == "unlock":
        # Wait for it and say what really happened (live 2026-11-20: "Asked your iPhone for Face ID" while his
        # permission had unlocked it silently, and the model stopped to wait for nothing).
        ok, note = _ensure_unlocked(did)
        if not ok:
            return json.dumps({"ok": False, "error": note})
        return json.dumps({"ok": True, "result": f"The {noun} is unlocked." if note else f"The {noun} is already unlocked."})
    out = (store.wake(did) if action == "wake" else store.let_sleep(did) if action == "sleep"
           else store.lock(did) if action == "lock" else store.unlock(did) if action == "unlock"
           else store.restart(did) if action == "restart" else store.shutdown(did) if action == "shutdown"
           else store.keep_awake(did, action == "keep_awake_on")) or {}
    if not out.get("ok"):
        return json.dumps({"ok": False, "error": out.get("error") or f"The {noun} didn't take it."})
    if out.get("delivered") is False and action in ("keep_awake_on", "keep_awake_off"):
        # The server keeps the switch and hands it over when the computer reconnects (review: it said "failed").
        state = "on" if action == "keep_awake_on" else "off"
        return json.dumps({"ok": True, "result": f"Keep awake is {state} for the {noun}; it takes effect when the "
                                                 f"{noun} is next awake."})
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
