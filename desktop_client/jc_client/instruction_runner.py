"""Continue a Mac Claude Code session from the phone when it isn't in tmux.

There is no terminal to type into, so the Mac runs ``claude -p <text> --resume
<session id>`` in the session's own folder, in the background; its hooks keep
reporting, so the island, the phone and any approval follow the run like any
other turn. The folder and the session id come from what this Mac's hooks
reported (``session_cwd``), never from the phone. One run per session at a
time. After coucou's InstructionRunner (github.com/Louis-CFM/coucou, MIT).
"""
from __future__ import annotations

import logging
import os
import shutil
import subprocess
from typing import Callable, Optional

log = logging.getLogger(__name__)

_CANDIDATES = ("~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude",
               "/usr/local/bin/claude", "~/.npm-global/bin/claude", "~/.bun/bin/claude")


def find_claude() -> Optional[str]:
    for path in _CANDIDATES:
        p = os.path.expanduser(path)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return shutil.which("claude")


class InstructionRunner:
    def __init__(self, *, session_cwd: Callable[[str], Optional[str]], log_dir: str,
                 popen=subprocess.Popen, find_claude: Callable[[], Optional[str]] = find_claude):
        self._session_cwd = session_cwd
        self._log_dir = log_dir
        self._popen = popen
        self._find_claude = find_claude
        self._running: dict = {}

    def run(self, session_id: str, _phone_cwd: str, text: str):
        """Start the run. Returns (ok, reason). ``_phone_cwd`` is ignored on purpose."""
        text = (text or "").strip()
        if not text:
            return False, "empty instruction"
        cwd = self._session_cwd(session_id) if session_id else None
        if not cwd or not os.path.isabs(cwd):
            return False, "unknown session on this Mac"
        proc = self._running.get(session_id)
        if proc is not None and proc.poll() is None:
            return False, "already running an instruction for this session"
        claude = self._find_claude()
        if not claude:
            return False, "can't find the claude command on this Mac"
        env = dict(os.environ)
        env["PATH"] = os.pathsep.join([os.path.dirname(claude), "/opt/homebrew/bin",
                                       "/usr/local/bin", env.get("PATH", "")])
        os.makedirs(self._log_dir, exist_ok=True)
        log_path = os.path.join(self._log_dir, f"instruction-{session_id[:8]}.log")
        try:
            out = open(log_path, "ab")
        except OSError:
            out = subprocess.DEVNULL
        try:
            self._running[session_id] = self._popen(
                [claude, "-p", text, "--resume", session_id], cwd=cwd, env=env,
                stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        except Exception as exc:  # noqa: BLE001
            return False, f"couldn't start claude: {exc}"
        finally:
            if out is not subprocess.DEVNULL:
                out.close()
        log.info("instruction from the phone started for %s in %s", session_id[:8], cwd)
        return True, "started"
