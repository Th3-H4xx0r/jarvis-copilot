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


TITLE_MAX = 120


def _title(name) -> str:
    """One line, at most TITLE_MAX characters: rosters go up on every heartbeat."""
    line = next((ln for ln in str(name or "").splitlines() if ln.strip()), "")
    line = " ".join(line.split())
    return line if len(line) <= TITLE_MAX else line[:TITLE_MAX - 1].rstrip() + "…"


_TITLE_TAIL = 512 * 1024
_TITLE_CACHE: dict = {}


def _transcript(cwd: str, session_id: str) -> str:
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    enc = os.path.realpath(cwd).replace("/", "-").replace(".", "-")
    return os.path.join(cfg, "projects", enc, f"{session_id}.jsonl")


def transcript_facts(cwd: str, session_id: str) -> tuple:
    """(title, last write time) of a Claude session's transcript: the newest
    ``ai-title`` (what the Claude app shows), read from the file's end and
    cached per size, and the file's mtime. (None, None) when it isn't there."""
    path = _transcript(cwd, session_id)
    try:
        st = os.stat(path)
    except OSError:
        return None, None
    hit = _TITLE_CACHE.get(path)
    if hit and hit[0] == st.st_size:
        return hit[1], st.st_mtime
    title = None
    try:
        with open(path, "rb") as fh:
            fh.seek(max(0, st.st_size - _TITLE_TAIL))
            data = fh.read()
        for line in reversed(data.split(b"\n")):
            if b'"ai-title"' not in line:
                continue
            try:
                raw = str(json.loads(line).get("aiTitle") or "").strip()
            except ValueError:
                continue
            if raw:
                title = _title(raw)
                break
    except OSError:
        pass
    _TITLE_CACHE[path] = (st.st_size, title)
    return title, st.st_mtime


def find_claude(home: Optional[str] = None, path_env: Optional[str] = None) -> Optional[str]:
    """The ``claude`` executable. jc-client runs under launchd, whose PATH
    (/usr/bin:/bin:/usr/sbin:/sbin) doesn't hold Claude Code's install dirs."""
    home = home or os.path.expanduser("~")
    path_env = os.environ.get("PATH", "") if path_env is None else path_env
    candidates = [os.path.join(d, "claude") for d in path_env.split(os.pathsep) if d]
    candidates += [os.path.join(home, ".local/bin/claude"), os.path.join(home, ".claude/local/claude"),
                   "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                   os.path.join(home, ".npm-global/bin/claude"), os.path.join(home, ".bun/bin/claude")]
    nvm = os.path.join(home, ".nvm/versions/node")
    try:
        for v in sorted(os.listdir(nvm), reverse=True):
            candidates.append(os.path.join(nvm, v, "bin/claude"))
    except OSError:
        pass
    return next((c for c in candidates if os.path.isfile(c) and os.access(c, os.X_OK)), None)


def claude_binary() -> str:
    return find_claude() or "claude"


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
                 claude_bin: Optional[str] = None) -> None:
        self._send = send
        self._run = run
        self._alive = alive
        self._clock = clock
        self._debounce = debounce
        self._heartbeat = heartbeat
        self._bin = claude_bin or claude_binary()
        self._lock = threading.Lock()
        self._terms: dict = {}      # (agent, session_id) -> terminal context from hooks
        self._codex: dict = {}      # session_id -> {pid, cwd}
        self._timer: Optional[threading.Timer] = None
        self._last: list = []
        # The agents the last scan could list: a failed `claude agents` leaves
        # Claude out, so the server doesn't take its silence for "all ended".
        self.last_agents: list = ["claude", "codex"]

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
        claude = self._claude_entries()
        entries = (claude or []) + self._codex_entries()
        agents = ["claude", "codex"] if claude is not None else ["codex"]
        self._last = entries
        self.last_agents = agents
        if send:
            self._send({"type": "event", "name": "agent_roster",
                        "data": {"entries": entries, "agents": agents}})
        return entries

    def close(self) -> None:
        with self._lock:
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None

    def _claude_entries(self) -> Optional[list]:
        """Claude's live sessions, or None when Claude couldn't be asked."""
        # Never through a pipe: a `claude` command can leave its daemon holding
        # the stdout it was given, and a pipe would then never reach EOF.
        try:
            with tempfile.TemporaryFile(mode="w+") as fh:
                out = self._run([self._bin, "agents", "--json"], stdout=fh,
                                stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True,
                                timeout=10)
                fh.seek(0)
                items = json.loads(fh.read() or "[]")
        except (OSError, ValueError, subprocess.SubprocessError):
            return None
        if getattr(out, "returncode", 0) not in (0, None) or not isinstance(items, list):
            return None
        out = []
        for s in items if isinstance(items, list) else []:
            sid = s.get("sessionId") if isinstance(s, dict) else None
            if not sid:
                continue
            bg = s.get("kind") == "background"
            if not bg and not (s.get("pid") and self._alive(s["pid"])):
                continue
            title, active = transcript_facts(s.get("cwd") or "", sid)
            out.append({"agent": "claude", "session_id": sid, "pid": s.get("pid"),
                        "title": title, "last_active_at": active,
                        "kind": "background" if bg else "interactive",
                        "bg_id": s.get("id") if bg else None, "cwd": s.get("cwd") or "",
                        "name": _title(s.get("name")), "status": s.get("status") or "",
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
