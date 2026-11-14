"""Codex plan usage, read the way Codex's own /status reads it.

``codex app-server`` speaks newline-delimited JSON-RPC on stdio: initialize,
initialized, then ``account/rateLimits/read``. The two windows come back as
``primary``/``secondary`` in no fixed order, so they are sorted by length
(a day or less is the 5-hour window). Output matches Claude Code's status-line
``rate_limits`` shape, so everything downstream reads both the same way.
After coucou's CodexPlanGauge (github.com/Louis-CFM/coucou, MIT).
"""
from __future__ import annotations

import json
import logging
import os
import select
import subprocess
import time
from typing import Optional

POLL_EVERY = 300.0
_REQUESTS = [
    {"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "jarvis", "version": "1"}}},
    {"method": "initialized"},
    {"id": 2, "method": "account/rateLimits/read"},
]


def parse_codex(result) -> Optional[dict]:
    limits = (result or {}).get("rateLimits") if isinstance(result, dict) else None
    if not isinstance(limits, dict):
        return None
    out: dict = {}
    for key in ("primary", "secondary"):
        w = limits.get(key)
        if not isinstance(w, dict):
            continue
        pct, reset = w.get("usedPercent"), w.get("resetsAt")
        if not isinstance(pct, (int, float)) or not isinstance(reset, (int, float)):
            continue
        window = {"used_percentage": min(100, max(0, pct)), "resets_at": reset}
        mins = w.get("windowDurationMins")
        slot = "five_hour" if isinstance(mins, (int, float)) and mins <= 24 * 60 else "seven_day"
        out[slot] = window
    if not out:
        return None
    if isinstance(limits.get("planType"), str):
        out["plan"] = limits["planType"]
    return out


def find_codex(home: Optional[str] = None, path_env: Optional[str] = None) -> Optional[str]:
    home = home or os.path.expanduser("~")
    path_env = os.environ.get("PATH", "") if path_env is None else path_env
    candidates = [os.path.join(d, "codex") for d in path_env.split(os.pathsep) if d]
    candidates += [os.path.join(home, ".local/bin/codex"), "/opt/homebrew/bin/codex",
                   "/usr/local/bin/codex", os.path.join(home, ".bun/bin/codex"),
                   os.path.join(home, "Library/pnpm/codex")]
    nvm = os.path.join(home, ".nvm/versions/node")
    try:
        for v in sorted(os.listdir(nvm), reverse=True):
            candidates.append(os.path.join(nvm, v, "bin/codex"))
    except OSError:
        pass
    return next((c for c in candidates if os.path.isfile(c) and os.access(c, os.X_OK)), None)


def read_codex(codex: str, timeout: float = 15.0) -> Optional[dict]:
    """One exchange with a fresh ``codex app-server``; None on any failure."""
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([os.path.dirname(codex), "/opt/homebrew/bin", "/usr/local/bin",
                                   "/usr/bin", "/bin", env.get("PATH", "")])
    try:
        proc = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, env=env)
    except OSError:
        return None
    try:
        proc.stdin.write(("\n".join(json.dumps(r) for r in _REQUESTS) + "\n").encode())
        proc.stdin.flush()
        deadline = time.monotonic() + timeout
        buf = b""
        fd = proc.stdout.fileno()
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            ready, _, _ = select.select([fd], [], [], left)
            if not ready:
                return None
            chunk = os.read(fd, 65536)
            if not chunk:
                return None
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if isinstance(msg, dict) and msg.get("id") == 2:
                    return parse_codex(msg.get("result"))
    except OSError:
        return None
    finally:
        try:
            proc.kill()
            proc.wait(timeout=2)
        except Exception:  # noqa: BLE001
            pass


class CodexPoller:
    """Reads Codex's limits every five minutes on a daemon thread (when Codex is installed)."""

    def __init__(self, on_usage, every: float = POLL_EVERY, find=find_codex, read=read_codex):
        import threading
        self._on_usage = on_usage
        self._every = every
        self._find = find
        self._read = read
        self._stop = threading.Event()
        self._thread = None

    def poll_once(self) -> bool:
        codex = self._find()
        if not codex:
            return False
        usage = self._read(codex)
        if not usage:
            return False
        self._on_usage(usage)
        return True

    def start(self) -> None:
        import threading
        if self._thread is not None:
            return

        def loop():
            while not self._stop.is_set():
                try:
                    self.poll_once()
                except Exception:  # noqa: BLE001 — usage is a nicety, never fatal
                    pass
                self._stop.wait(self._every)

        self._thread = threading.Thread(target=loop, name="codex-usage", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()


# ── Claude, from the Jarvis server ───────────────────────────────────────
#
# Claude Code reports plan usage only through its status line, and only while a
# session is running (and not at all when another tool owns the status line).
# The server keeps Anthropic's own usage numbers fresh every 60 s (what the phone
# shows), so the Mac asks it as often and shows whichever is newer.

CLAUDE_POLL_EVERY = 60.0
_SAME_WINDOW = 60.0
_WINDOWS = ("five_hour", "seven_day")


def _num(value) -> Optional[float]:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def fresher_claude(server: Optional[dict], local: Optional[dict], now: Optional[float] = None) -> Optional[dict]:
    """Claude's limits from the server's snapshot and this Mac's status lines, per window.

    A local window counts only while it hasn't reset (status lines stop when
    sessions do, so a days-old one must not win). Within the same window the
    higher use wins (use only grows); a later window beats an earlier one; a
    window the server has no reset time for (not started yet) yields to a live
    local one. Shape: ``{five_hour: {used_percentage, resets_at|None}, seven_day, plan?}``.
    """
    now = time.time() if now is None else now
    server = server if isinstance(server, dict) else {}
    local = local if isinstance(local, dict) else {}
    out: dict = {}
    for name in _WINDOWS:
        s, l = server.get(name), local.get(name)
        s = s if isinstance(s, dict) and _num(s.get("used_percentage")) is not None else None
        l_reset = _num(l.get("resets_at")) if isinstance(l, dict) else None
        l = l if (l_reset is not None and l_reset > now and _num(l.get("used_percentage")) is not None) else None
        pick = s or l
        if s and l:
            s_reset = _num(s.get("resets_at"))
            if s_reset is None or l_reset > s_reset + _SAME_WINDOW:
                pick = l
            elif abs(l_reset - s_reset) <= _SAME_WINDOW and _num(l["used_percentage"]) > _num(s["used_percentage"]):
                pick = l
        if pick:
            out[name] = {"used_percentage": min(100.0, max(0.0, _num(pick["used_percentage"]))),
                         "resets_at": _num(pick.get("resets_at"))}
    if not out:
        return None
    plan = server.get("plan") or local.get("plan")
    if isinstance(plan, str) and plan:
        out["plan"] = plan
    return out


class ClaudeUsagePoller:
    """Asks the server for Claude's limits every minute, on a daemon thread.

    ``get(path)`` returns the decoded JSON body (raising on failure); the answer
    of ``GET /api/coding/agents/usage`` is ``{claude, codex}``.
    """

    PATH = "/api/coding/agents/usage"

    def __init__(self, get, on_usage, every: float = CLAUDE_POLL_EVERY):
        import threading
        self._get = get
        self._on_usage = on_usage
        self._every = every
        self._stop = threading.Event()
        self._thread = None

    def poll_once(self) -> bool:
        body = self._get(self.PATH)
        claude = body.get("claude") if isinstance(body, dict) else None
        if not isinstance(claude, dict) or not any(isinstance(claude.get(w), dict) for w in _WINDOWS):
            return False
        self._on_usage(claude)
        return True

    def start(self) -> None:
        import threading
        if self._thread is not None:
            return

        def loop():
            failing = False
            while not self._stop.is_set():
                try:
                    self.poll_once()
                    failing = False
                except Exception as exc:  # noqa: BLE001 — offline or unpaired: try again next minute
                    if not failing:     # once per outage, not every minute
                        logging.getLogger(__name__).info("claude usage from the server failed: %r", exc)
                    failing = True
                self._stop.wait(self._every)

        self._thread = threading.Thread(target=loop, name="claude-usage", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
