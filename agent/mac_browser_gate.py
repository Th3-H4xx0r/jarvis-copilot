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
)
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
_pinned: set = set()

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


def _from_mac(task_id) -> bool:
    """Whether this turn came from the user's Mac (its paired desktop app)."""
    try:
        from api import turn_origin
        return turn_origin.kind_for_session(task_id) == "desktop"
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


def note_turn(task_id: Optional[str], text, *, prev_assistant=None) -> None:
    """Record whether this turn's user message allows the Mac browser (fails closed).
    A pinned turn (a background job / subagent of a parent turn) keeps the parent's
    decision instead of re-reading model-written text."""
    if not task_id:
        return
    try:
        allowed = explicit_mac_request(text, from_mac=_from_mac(task_id), prev_assistant=prev_assistant)
    except Exception:
        allowed = False
    with _lock:
        if task_id in _pinned:
            return
        _remember(task_id, allowed)


def pin(task_id: Optional[str], allowed: bool) -> None:
    """Fix a child turn's decision to its parent's (``allowed(parent_task_id)``)."""
    if not task_id:
        return
    with _lock:
        _pinned.add(task_id)
        _remember(task_id, bool(allowed))


def allowed(task_id: Optional[str]) -> bool:
    with _lock:
        return _allowed.get(task_id or "", False)


def _remember(task_id: str, value: bool) -> None:
    _allowed[task_id] = value
    _allowed.move_to_end(task_id)
    while len(_allowed) > _MAX_TURNS:
        old, _ = _allowed.popitem(last=False)
        _pinned.discard(old)


def block_message(tool_name: str, task_id: Optional[str]) -> Optional[str]:
    """The reason to refuse ``tool_name`` this turn, or None to let it run."""
    if is_mac_browser_tool(tool_name):
        return None if allowed(task_id) else BLOCK_MESSAGE
    if is_mac_control_tool(tool_name):
        return None if allowed(task_id) else CONTROL_BLOCK_MESSAGE
    return None


def reset_for_tests() -> None:
    with _lock:
        _allowed.clear()
        _pinned.clear()
