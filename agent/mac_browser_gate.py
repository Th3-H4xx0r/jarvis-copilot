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

_MAC_TOOL_PREFIXES = ("chrome_", "mcp_playwright_desktop")
_DEVICE = r"(?:mac(?:book)?(?:\s+(?:pro|air))?|laptop|computer|desktop|chrome|browser)"
# "my mac", "my laptop's chrome", "in my browser", "my own computer", "mac chrome"
_ASK = re.compile(
    rf"\bmy\s+(?:own\s+)?{_DEVICE}\b|\b(?:mac(?:book)?|desktop)\s+(?:chrome|browser)\b",
    re.IGNORECASE,
)
# "don't use my browser", "not on my mac", "instead of my laptop"
_NEGATED = re.compile(r"\b(?:don'?t|do\s+not|never|not|without|instead\s+of)\b(?:\W+\w+){0,3}\W*$",
                      re.IGNORECASE)
_MAX_TURNS = 2000

_lock = threading.Lock()
_allowed: "OrderedDict[str, bool]" = OrderedDict()

BLOCK_MESSAGE = (
    "Blocked: this tool drives the user's own Mac browser, which is only used when the user "
    "explicitly asks for it. Use the headless browser and web tools on the server instead. "
    "If this really needs the user's Mac browser, ask the user first."
)


def explicit_mac_request(text: Optional[str]) -> bool:
    """True when the text asks for the user's own Mac / browser ("open it in my browser")."""
    for m in _ASK.finditer(text or ""):
        if not _NEGATED.search((text or "")[:m.start()]):
            return True
    return False


def is_mac_browser_tool(name: Optional[str]) -> bool:
    return str(name or "").startswith(_MAC_TOOL_PREFIXES)


def note_turn(task_id: Optional[str], text: Optional[str]) -> None:
    """Record whether this turn's user message allows the Mac browser."""
    if not task_id:
        return
    with _lock:
        _allowed[task_id] = explicit_mac_request(text)
        _allowed.move_to_end(task_id)
        while len(_allowed) > _MAX_TURNS:
            _allowed.popitem(last=False)


def block_message(tool_name: str, task_id: Optional[str]) -> Optional[str]:
    """The reason to refuse ``tool_name`` this turn, or None to let it run."""
    if not is_mac_browser_tool(tool_name):
        return None
    with _lock:
        allowed = _allowed.get(task_id or "", False)
    return None if allowed else BLOCK_MESSAGE


def reset_for_tests() -> None:
    with _lock:
        _allowed.clear()
