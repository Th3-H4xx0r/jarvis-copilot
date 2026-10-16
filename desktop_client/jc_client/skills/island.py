"""`jarvis_island`: open the Jarvis Mac app's notch island on one tab.

The skill runs inside jc-client; the app listens on ui.sock, so the service
hands this module its broadcast (``set_broadcast``) when it starts the hook
server. Nothing happens unless the Mac app is running.
"""
from __future__ import annotations

import os
from typing import Callable, Optional

from jc_client.skills import skill

TABS = ("agents", "chat", "music", "recap")
_broadcast: Optional[Callable[[dict], None]] = None


def set_broadcast(fn: Optional[Callable[[dict], None]]) -> None:
    global _broadcast
    _broadcast = fn


def _app_running() -> bool:
    from jc_client.logger import state_dir
    return os.path.exists(str(state_dir() / "mac-app.running"))


@skill(
    "jarvis_island",
    "Open the Jarvis island at the top of this Mac's screen on one tab: agents (coding agents and "
    "what waits on you), chat, music (now playing), or recap (the week with the agents). For chat, "
    "`text` pre-fills the message box.",
    {
        "type": "object",
        "properties": {
            "tab": {"type": "string", "enum": list(TABS)},
            "text": {"type": "string", "description": "Chat only: a draft for the message box."},
        },
        "required": ["tab"],
    },
)
def jarvis_island(tab: str = "agents", text: str = "") -> dict:
    if tab not in TABS:
        raise ValueError(f"tab must be one of {', '.join(TABS)}")
    if _broadcast is None or not _app_running():
        return {"ok": False, "error": "The Jarvis app isn't running on this Mac."}
    msg = {"type": "island", "tab": tab}
    if tab == "chat" and text:
        msg["text"] = text[:4000]
    _broadcast(msg)
    return {"ok": True, "tab": tab}
