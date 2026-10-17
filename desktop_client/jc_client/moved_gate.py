"""Refuse new work in a session's stale Mac copy once it continued elsewhere.

When a session continues on the server while the Mac sleeps, the Mac's own
Claude/Codex process is still there in its terminal, frozen with the old
conversation in memory. If it took a prompt it would fork the conversation.
Its hooks ask here first (``UserPromptSubmit`` and ``PreToolUse`` wait for an
answer), and a moved session is refused with a one-line reason.

Right after wake jc-client doesn't yet know what moved: the gate holds for up
to ~10 s until the server says (``set_moved``). If the server can't be reached
in that time the prompt goes through, so offline work on the Mac still works;
a fork that results is kept as a separate copy when the copies merge.
"""
from __future__ import annotations

import threading
import time

REASON = "This session continued on the server. Use Jarvis to bring it back."


class MovedGate:
    def __init__(self, clock=time.monotonic) -> None:
        self._clock = clock
        self._moved: set = set()
        self._lock = threading.Lock()
        self._confirmed = threading.Event()
        self._confirmed.set()
        self._hold_until = 0.0

    def set_moved(self, ckeys) -> None:
        """The server's word on what moved (also confirms after a wake)."""
        with self._lock:
            self._moved = set(ckeys or ())
        self._confirmed.set()

    def add(self, ckey: str) -> None:
        with self._lock:
            self._moved.add(ckey)

    def discard(self, ckey: str) -> None:
        with self._lock:
            self._moved.discard(ckey)

    def hold_until_confirmed(self, seconds: float = 10.0) -> None:
        with self._lock:
            self._hold_until = self._clock() + seconds
        self._confirmed.clear()

    def check(self, agent: str, session_id: str) -> tuple:
        if not self._confirmed.is_set():
            left = self._hold_until - self._clock()
            if left > 0:
                self._confirmed.wait(left)
        with self._lock:
            moved = f"{agent}|{session_id}" in self._moved
        return ("block", REASON) if moved else ("allow", "")
