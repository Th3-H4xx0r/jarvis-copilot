"""This Mac's roster of live coding-agent sessions, for the server.

Claude Code lists its own live sessions (interactive and background) with
``claude agents --json``; Codex has no such list, so its sessions come from
their hooks and stay listed while their process lives. The roster is sent
on hooks that start or end a session, on wake and reconnect, and on a slow
heartbeat only while something is live (no polling when idle: battery). The
hooks also give each session's terminal (VS Code, iTerm, ...), which the
roster carries so Jarvis knows where it can type.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import tempfile
import threading
import time
from typing import Callable, Optional

log = logging.getLogger(__name__)


def _pid_alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


class RosterAgent:
    def __init__(self, send: Callable[[dict], None], *, run: Callable = subprocess.run,
                 alive: Callable[[int], bool] = _pid_alive, clock=time.time,
                 debounce: float = 1.0, heartbeat: float = 60.0,
                 claude_bin: str = "claude") -> None:
        self._send = send
        self._run = run
        self._alive = alive
        self._clock = clock
        self._debounce = debounce
        self._heartbeat = heartbeat
        self._bin = claude_bin
        self._lock = threading.Lock()
        self._terms: dict = {}      # (agent, session_id) -> terminal context from hooks
        self._codex: dict = {}      # session_id -> {pid, cwd}
        self._timer: Optional[threading.Timer] = None
        self._last: list = []

    def note_hook(self, agent: str, session_id: str, *, pid=None, cwd: str = "",
                  terminal: Optional[dict] = None, ended: bool = False) -> None:
        if not session_id:
            return
        with self._lock:
            if terminal:
                self._terms[(agent, session_id)] = dict(terminal)
            if agent == "codex":
                if ended:
                    self._codex.pop(session_id, None)
                elif pid:
                    self._codex[session_id] = {"pid": int(pid), "cwd": cwd}

    def trigger(self, reason: str = "") -> None:
        with self._lock:
            if self._timer is not None:
                return
            self._timer = threading.Timer(self._debounce, self._fire)
            self._timer.daemon = True
            self._timer.start()

    def _fire(self) -> None:
        with self._lock:
            self._timer = None
        try:
            self.scan_now()
        except Exception:  # noqa: BLE001
            log.debug("roster scan failed", exc_info=True)
        nxt = self.next_heartbeat()
        if nxt is not None:
            with self._lock:
                if self._timer is None:
                    self._timer = threading.Timer(nxt, self._fire)
                    self._timer.daemon = True
                    self._timer.start()

    def next_heartbeat(self) -> Optional[float]:
        return self._heartbeat if self._last else None

    def snapshot(self) -> list:
        return list(self._last)

    def scan_now(self, send: bool = True) -> list:
        entries = self._claude_entries() + self._codex_entries()
        self._last = entries
        if send:
            self._send({"type": "event", "name": "agent_roster",
                        "data": {"entries": entries, "agents": ["claude", "codex"]}})
        return entries

    def close(self) -> None:
        with self._lock:
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None

    def _claude_entries(self) -> list:
        # Never through a pipe: a `claude` command can leave its daemon holding
        # the stdout it was given, and a pipe would then never reach EOF.
        try:
            with tempfile.TemporaryFile(mode="w+") as fh:
                self._run([self._bin, "agents", "--json"], stdout=fh, stderr=subprocess.DEVNULL,
                          stdin=subprocess.DEVNULL, text=True, timeout=10)
                fh.seek(0)
                items = json.loads(fh.read() or "[]")
        except (OSError, ValueError, subprocess.SubprocessError):
            return []
        out = []
        for s in items if isinstance(items, list) else []:
            sid = s.get("sessionId") if isinstance(s, dict) else None
            if not sid:
                continue
            bg = s.get("kind") == "background"
            if not bg and not (s.get("pid") and self._alive(s["pid"])):
                continue
            out.append({"agent": "claude", "session_id": sid, "pid": s.get("pid"),
                        "kind": "background" if bg else "interactive",
                        "bg_id": s.get("id") if bg else None, "cwd": s.get("cwd") or "",
                        "name": s.get("name") or "", "status": s.get("status") or "",
                        "terminal": self._terms.get(("claude", sid)) or {}})
        return out

    def _codex_entries(self) -> list:
        out = []
        with self._lock:
            items = list(self._codex.items())
        for sid, info in items:
            if not self._alive(info["pid"]):
                with self._lock:
                    self._codex.pop(sid, None)
                continue
            out.append({"agent": "codex", "session_id": sid, "pid": info["pid"],
                        "kind": "interactive", "bg_id": None, "cwd": info.get("cwd") or "",
                        "name": "", "status": "",
                        "terminal": self._terms.get(("codex", sid)) or {}})
        return out
