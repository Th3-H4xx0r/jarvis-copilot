"""The phone's next instruction, delivered to the LIVE session on this Mac.

Never a background `claude -p --resume`: on a session that is still open in a
window that forks the conversation into a second copy that acts on its own.

* A working session gets the message when it finishes its current step: the
  Stop hook (jc-hook) asks for it and answers Claude Code with
  ``{"decision": "block", "reason": …}``, which makes Claude carry on with it in
  the same window. Works in any terminal, VS Code included.
* An idle session gets it typed in: in VS Code's terminal through the Jarvis
  Terminal Bridge extension (found by the session's process id), or in an
  iTerm session by AppleScript.
"""
from __future__ import annotations

import subprocess
import threading
import time
from typing import Callable

QUEUE_TTL = 2 * 3600.0

# iTerm2: find the session by its unique id and type the text. Both arrive as
# arguments, so the text is data and never part of the script.
_ITERM_SCRIPT = [
    "on run argv",
    'tell application "iTerm2"',
    "repeat with w in windows",
    "repeat with t in tabs of w",
    "repeat with s in sessions of t",
    "if (unique id of s) is (item 1 of argv) then",
    "tell s to write text (item 2 of argv)",
    "return",
    "end if",
    "end repeat",
    "end repeat",
    "end repeat",
    "end tell",
    "end run",
]


class InstructionQueue:
    """Messages waiting for a session's next Stop, per session id."""

    def __init__(self, clock: Callable[[], float] = time.time) -> None:
        self._clock = clock
        self._lock = threading.Lock()
        self._items: dict[str, list[tuple[float, str]]] = {}

    def add(self, session_id: str, text: str) -> None:
        with self._lock:
            self._items.setdefault(session_id, []).append((self._clock(), text))

    def pending(self, session_id: str) -> int:
        with self._lock:
            return len(self._items.get(session_id, []))

    def take(self, session_id: str) -> Optional[str]:
        now = self._clock()
        with self._lock:
            items = self._items.pop(session_id, [])
        fresh = [text for at, text in items if now - at <= QUEUE_TTL]
        return "\n\n".join(fresh) if fresh else None


def stop_reply(text: str) -> dict:
    """What the Stop hook answers so Claude continues with the message."""
    return {"decision": "block",
            "reason": "Pranav sent this from his phone (Jarvis, Agents tab). Do it now:\n\n" + text}


def type_into(terminal: dict, text: str, *, pid=None, vscode=None,
              run: Callable[[list], int] = None) -> tuple[bool, str]:
    """Type ``text`` + Return into the terminal running the session."""
    run = run or (lambda argv: subprocess.run(argv, timeout=10, capture_output=True).returncode)
    terminal = terminal or {}
    if str(terminal.get("term_program") or "").lower() == "vscode":
        shell = vscode.terminal_pid_for(int(pid)) if (vscode is not None and pid) else None
        if not shell:
            return False, "VS Code isn't showing that session (is the Jarvis extension on?)"
        if not vscode.send_text(shell, text):
            return False, "VS Code couldn't type into that terminal"
        return True, "typed into VS Code"
    iterm = str(terminal.get("iterm") or "")
    if iterm:
        uid = iterm.split(":", 1)[-1]
        argv = ["/usr/bin/osascript"]
        for line in _ITERM_SCRIPT:
            argv += ["-e", line]
        argv += [uid, text]
        if run(argv) != 0:
            return False, "iTerm couldn't type into that session"
        return True, "typed into iTerm"
    return False, "can't type into this terminal"


def _exists(path: str) -> bool:
    import os
    return os.path.exists(path)
