"""The user's own Mac browser only when they ask for it.

Pranav (2026-10-11): "it must only use this headless method for these type of
research and tasks, and ONLY resort to driving the browser on my mac if i
specifically tell it to."

Research and browsing run on the server's headless browser. The tools that drive
the browser on his Mac — the ``chrome_*`` device skills and the desktop Playwright
MCP servers (``mcp_playwright_desktop*``) — are blocked by the pre-tool check
(``jarviscopilot_cli.plugins.get_pre_tool_call_block_message``) unless this
turn's user message explicitly asks for his Mac / his browser. The turn's text is
recorded where every surface starts a turn (``agent.conversation_loop``); a
harness background turn's prompt carries the parent chat's latest user message,
so it follows his own words too.
"""
from __future__ import annotations

import json
import re
import threading
from collections import OrderedDict
from typing import Optional

# chrome_* device skills (the server's own and the Mac app's, which arrive as
# device_chrome_*), and the desktop Playwright MCP servers (direct + relay).
_MAC_TOOL_PREFIXES = ("chrome_", "device_chrome_", "mcp_playwright_desktop", "mcp_playwright_relay_")
# Driving the Mac itself — the fast computer-control loop and jc-client's
# screen / mouse / keyboard skills — follows the same rule.
_MAC_CONTROL_PREFIXES = ("computer_do", "device_ui_", "device_mouse_", "device_type_text", "device_key_",
                         "device_system_command", "device_run_shell", "device_quit_app", "device_focus_window")
_TARGET = r"(?:mac(?:book)?(?:\s+(?:pro|air))?|laptop|computer|desktop)"
_BROWSER = r"(?:chrome|browser)"
_ASKS = (
    # "on my mac", "in Chrome on the Mac", "pull up kayak on my MacBook"
    re.compile(rf"\b(?:on|in|with|using|via|through|from)\s+(?:the\s+|my\s+(?:own\s+)?){_TARGET}\b", re.I),
    # "in my browser", "in my Chrome", "with my laptop's browser"
    re.compile(rf"\b(?:on|in|with|using|via|through)\s+my\s+(?:own\s+)?(?:{_TARGET}(?:'s)?\s+)?{_BROWSER}\b", re.I),
    # "use my mac", "drive my mac browser", "use my computer's browser"
    re.compile(rf"\b(?:use|drive|control|open\s+up|pull\s+up)\s+my\s+(?:own\s+)?(?:{_TARGET}(?:'s)?\s+)?"
               rf"(?:{_TARGET}|{_BROWSER})\b", re.I),
    # "on my screen", "on my Mac's screen" — "the screen" alone is not an ask
    re.compile(rf"\b(?:on|in|from)\s+my\s+(?:own\s+)?(?:{_TARGET}(?:'s)?\s+)?screen\b", re.I),
    # "look at my screen", "check my Mac's screen", "a screenshot of my screen",
    # "describe what's on my display" (live 2026-10-16: "look at my screen" was refused)
    re.compile(rf"\b(?:look(?:ing)?\s+at|see|check|read|view|scan|describe|analy[sz]e|glance\s+at|screenshot)"
               rf"\s+(?:of\s+)?(?:what(?:'s|\s+is)\s+on\s+)?my\s+(?:own\s+)?(?:{_TARGET}(?:'s)?\s+)?"
               rf"(?:screen|display|monitor)\b", re.I),
    # "use computer control", "do it with visual control", "you must choose Computer Control"
    # (live 2026-10-30: "use visual control with clicks to do this" was refused)
    re.compile(r"\b(?:computer|visual|screen|mac|desktop)[\s-]+control\b", re.I),
)
# "stop using my Mac", "no more controlling my laptop" — takes a chat's ask back.
_STOP_MAC = re.compile(rf"\b(?:stop|quit|no\s+more)\s+(?:using|controlling|driving|touching)\s+(?:the\s+|my\s+(?:own\s+)?)"
                       rf"{_TARGET}\b", re.I)
# Said to the Mac itself (its voice panel or app): a show-me request means this screen.
_SHOW = re.compile(r"\b(?:open|show(?:\s+me)?|pull\s+up|bring\s+up|go\s+to|navigate\s+to|play|launch|"
                   r"put\s+on|start)\b", re.I)
# A yes to Jarvis asking about the Mac: "Yes, you have full authorization", "go ahead".
_CONSENT = re.compile(r"\b(?:yes|yeah|yep|sure|ok(?:ay)?|go\s+ahead|do\s+it|please\s+do|you\s+(?:have|got)\s+"
                      r"(?:full\s+|my\s+)?(?:permission|authori[sz]ation)|you(?:'re|\s+are)\s+(?:allowed|authori[sz]ed)|"
                      r"i\s+authori[sz]e|permission\s+granted)\b", re.I)
_REFUSAL = re.compile(r"^\W*(?:no|nope|don't|do\s+not|never|stop|cancel)\b", re.I)
_MAC_WORDS = re.compile(rf"\b(?:{_TARGET}|{_BROWSER}|safari|screen)\b", re.I)
# "don't use my browser", "not on my mac", "instead of my laptop" — but not "why not".
_NEGATED = re.compile(r"\b(?:don't|do\s+not|never|(?<!\bwhy\s)not|without|instead\s+of)\b(?:\W+\w+){0,3}\W*$",
                      re.IGNORECASE)
_MAX_TURNS = 2000

_lock = threading.Lock()
_allowed: "OrderedDict[str, bool]" = OrderedDict()
# Chats where he asked for his Mac, and the device that ask came from: every later turn
# in that chat ("Continue.", "try again", "now open the second one") keeps it until he
# takes it back (Pranav 2026-11-03: "Mac OK lasts the chat"). Same device only: his
# voice chat is the same on the Mac and in the car, and a car turn must not drive the
# Mac on a Mac turn's say-so (2026-10-21 00:01).
_asked_from: "OrderedDict[str, Optional[str]]" = OrderedDict()
_pinned: set = set()
# This turn's words, for tools that pick a device from what he said ("on my MacBook").
_turn_text: "OrderedDict[str, str]" = OrderedDict()

BLOCK_MESSAGE = (
    "Blocked: this tool drives the user's own Mac browser, which is only used when the user "
    "explicitly asks for it. Use the headless browser and web tools on the server instead. "
    "If this really needs the user's Mac browser, ask the user first."
)


def _text(content) -> str:
    """The words of a message: a string, or the text parts of a multimodal list."""
    if isinstance(content, list):
        return " ".join(str(p.get("text") or "") for p in content
                        if isinstance(p, dict) and p.get("type") in (None, "text", "input_text"))
    return str(content or "")


def explicit_mac_request(text, *, from_mac: bool = False, prev_assistant=None) -> bool:
    """True when the user asks for their own Mac / browser ("open it in my browser"),
    asks the Mac itself to show something (``from_mac``: said to its voice panel or
    app), or says yes to Jarvis asking about the Mac (``prev_assistant``)."""
    t = _text(text).replace("’", "'")
    if _STOP_MAC.search(t):  # "stop using my Mac" reads like "using my Mac"
        return False
    for pattern in _ASKS:
        for m in pattern.finditer(t):
            if not _NEGATED.search(t[:m.start()]):
                return True
    if _REFUSAL.search(t):
        return False
    if from_mac and _SHOW.search(t):
        return True
    prev = _text(prev_assistant or "")
    return bool(prev and _CONSENT.search(t) and _MAC_WORDS.search(prev))


def explicit_mac_refusal(text) -> bool:
    """True when the user takes the Mac back: "don't use my Mac", "not in my browser",
    "stop using my laptop"."""
    t = _text(text).replace("’", "'")
    if _STOP_MAC.search(t):
        return True
    return any(_NEGATED.search(t[:m.start()]) for pattern in _ASKS for m in pattern.finditer(t))


def asked_earlier(history) -> bool:
    """Whether an earlier user turn of this chat asked for the Mac (or said yes to Jarvis
    asking) and no later turn took it back. Used when the server restarted mid-chat and
    lost the turn it remembered."""
    asked, prev = False, None
    for m in history or []:
        if not isinstance(m, dict):
            continue
        if m.get("role") == "assistant" and m.get("content"):
            prev = m.get("content")
        elif m.get("role") == "user":
            text = m.get("content")
            if explicit_mac_request(text, prev_assistant=prev):
                asked = True
            elif explicit_mac_refusal(text):
                asked = False
    return asked


def _voice_off_the_mac(task_id) -> bool:
    """A spoken turn from somewhere other than the Mac (the phone, the car)."""
    try:
        from api import turn_origin
        return turn_origin.is_voice_session(task_id) and not turn_origin.is_mac_session(task_id)
    except Exception:
        return False


def _from_mac(task_id) -> bool:
    """Whether this turn came from the user's Mac (its paired desktop app)."""
    try:
        from api import turn_origin
        return turn_origin.is_mac_session(task_id)
    except Exception:
        return False


CONTROL_BLOCK_MESSAGE = (
    "Blocked: this drives the user's own Mac (its screen, mouse and keyboard), which is only done when the "
    "user explicitly asks for it (e.g. \"on my Mac\"). Ask the user first."
)


def is_mac_browser_tool(name: Optional[str]) -> bool:
    return str(name or "").startswith(_MAC_TOOL_PREFIXES)


def is_mac_control_tool(name: Optional[str]) -> bool:
    return str(name or "").startswith(_MAC_CONTROL_PREFIXES)


def note_turn(task_id: Optional[str], text, *, prev_assistant=None, history=None) -> None:
    """Record whether this turn's user message allows the Mac browser (fails closed).
    An ask lasts the rest of the chat on the same device; ``history`` (the chat's earlier
    messages) restores it after a server restart. A pinned turn (a background job /
    subagent of a parent turn) keeps the parent's decision instead of re-reading
    model-written text."""
    if not task_id:
        return
    parent = str(task_id).split("~", 1)[0] if "~" in str(task_id) else None
    if not parent:
        with _lock:
            _turn_text[task_id] = _text(text)[:2000]
            _turn_text.move_to_end(task_id)
            while len(_turn_text) > _MAX_TURNS:
                _turn_text.popitem(last=False)
    if parent:
        # A harness background job ("<chat>~<node>"): its text is model-written, so it
        # follows the chat turn that started it and never unlocks the Mac itself.
        with _lock:
            if task_id not in _pinned:
                _remember(task_id, _allowed.get(parent, False))
        return
    try:
        allowed = explicit_mac_request(text, from_mac=_from_mac(task_id), prev_assistant=prev_assistant)
        refused = not allowed and explicit_mac_refusal(text)
    except Exception:
        allowed, refused = False, False
    device = _turn_device(task_id)
    from_history = False
    if not allowed and not refused and history and not _voice_off_the_mac(task_id):
        try:
            from_history = asked_earlier(history)
        except Exception:
            from_history = False
    with _lock:
        if task_id in _pinned:
            return
        if refused:
            _asked_from.pop(task_id, None)
        elif allowed:
            _asked_from[task_id] = device
        elif task_id in _asked_from:
            allowed = _asked_from[task_id] == device
        elif from_history:
            allowed = True
            _asked_from[task_id] = device
        if task_id in _asked_from:
            _asked_from.move_to_end(task_id)
            while len(_asked_from) > _MAX_TURNS:
                _asked_from.popitem(last=False)
        _remember(task_id, allowed)


def _turn_device(task_id) -> Optional[str]:
    """The paired device this chat's current turn came from (None when unknown)."""
    try:
        from api import turn_origin
        return turn_origin.device_for_session(task_id)
    except Exception:
        return None


def pin(task_id: Optional[str], allowed: bool) -> None:
    """Fix a child turn's decision to its parent's (``allowed(parent_task_id)``)."""
    if not task_id:
        return
    with _lock:
        _pinned.add(task_id)
        _remember(task_id, bool(allowed))


def turn_text(task_id: Optional[str]) -> str:
    """The user's words for this chat's current turn (a background job: its chat's)."""
    key = str(task_id or "").split("~", 1)[0]
    with _lock:
        return _turn_text.get(key, "")


def allowed(task_id: Optional[str]) -> bool:
    with _lock:
        return _allowed.get(task_id or "", False)


def _remember(task_id: str, value: bool) -> None:
    _allowed[task_id] = value
    _allowed.move_to_end(task_id)
    while len(_allowed) > _MAX_TURNS:
        old, _ = _allowed.popitem(last=False)
        _pinned.discard(old)


# Reading the Mac's screen (no clicking, no typing): a turn from the Mac itself —
# its push to talk or its island chat — may look at what's on it unasked
# (Pranav 2026-10-16: push to talk should "collect auto context on what I'm
# seeing"). Driving the Mac still needs an explicit ask.
_LOOK_TOOLS = frozenset({"device_ui_look"})


SPOTIFY_BLOCK_MESSAGE = (
    "Blocked: music in Spotify is never played by driving the Mac's screen. Use spotify_playback "
    "(search for it, then play): on a turn from the Mac it plays in the Mac's Spotify app itself, "
    "opening Spotify if it's closed."
)
_PLAY_WORDS = re.compile(r"\b(?:play(?:ing)?|put\s+on|start|queue|listen)\b", re.I)


def _plays_spotify(args) -> bool:
    """Whether a computer_do call is about playing something in Spotify."""
    if not isinstance(args, dict):
        return False
    parts = [args.get("goal"), args.get("app")]
    for step in args.get("steps") or []:
        if isinstance(step, dict):
            parts += [step.get("do"), step.get("app"), step.get("text")]
    text = " ".join(str(p) for p in parts if p)
    return "spotify" in text.lower() and bool(_PLAY_WORDS.search(text))


# The clipboard can hold passwords and API keys: it is copied or read only when he asks
# (live 2026-10-09: cmd+A, cmd+C in the wrong window, then clipboard_read put an API key
# into the chat).
CLIPBOARD_BLOCK_MESSAGE = (
    "Blocked: the user's clipboard is only copied to or read when they ask for it (it can hold passwords "
    "and keys). Read the text from the screen instead."
)
_CLIPBOARD_ASK = re.compile(r"\b(?:clipboard|pasteboard|copy|copied|copying|paste|pasted|pasting)\b", re.I)
_CLIPBOARD_SHELL = re.compile(r"\bpbpaste\b|\bthe\s+clipboard\b|NSPasteboard|\bpbcopy\b", re.I)
_SHELL_TOOLS = ("device_run_shell", "device_system_command", "device_applescript", "device_osascript")
_COPY_MODIFIERS = {"cmd", "command", "⌘", "meta", "super"}


def clipboard_asked(text) -> bool:
    """Whether the user's words ask for copying / pasting / the clipboard."""
    return bool(_CLIPBOARD_ASK.search(_text(text)))


def is_copy_combo(keys) -> bool:
    """cmd+C / cmd+X in any spelling ("cmd+c", ["command", "c"], "⌘C")."""
    if isinstance(keys, (list, tuple)):
        parts = [str(k) for k in keys]
    else:
        parts = re.split(r"[+\s,-]+", str(keys or "").replace("⌘", "⌘+"))
    parts = {p.strip().lower() for p in parts if p and p.strip()}
    return bool(parts & _COPY_MODIFIERS) and bool(parts & {"c", "x"})


def _clipboard_use(tool_name: str, args) -> bool:
    """Whether this call copies to or reads the clipboard."""
    name = str(tool_name or "")
    if "clipboard" in name and not name.endswith(("_write", "_set")):
        return True
    if not isinstance(args, dict):
        return False
    if name.startswith(("device_key_", "device_ui_do")) and is_copy_combo(args.get("keys")):
        return True
    if name.startswith(_SHELL_TOOLS):
        return bool(_CLIPBOARD_SHELL.search(json.dumps(args, ensure_ascii=False)))
    return False


def block_message(tool_name: str, task_id: Optional[str], args=None) -> Optional[str]:
    """The reason to refuse ``tool_name`` this turn, or None to let it run."""
    if _clipboard_use(tool_name, args) and not clipboard_asked(turn_text(task_id)):
        return CLIPBOARD_BLOCK_MESSAGE
    if is_mac_browser_tool(tool_name):
        return None if allowed(task_id) else BLOCK_MESSAGE
    if tool_name == "computer_do" and _plays_spotify(args):
        # Live 2026-10-21 00:01: it clicked into Spotify's search box and typed nothing.
        return SPOTIFY_BLOCK_MESSAGE
    if is_mac_control_tool(tool_name):
        if allowed(task_id) or (tool_name in _LOOK_TOOLS and _from_mac(task_id)):
            return None
        return CONTROL_BLOCK_MESSAGE
    return None


def reset_for_tests() -> None:
    with _lock:
        _allowed.clear()
        _pinned.clear()
        _asked_from.clear()
        _turn_text.clear()
