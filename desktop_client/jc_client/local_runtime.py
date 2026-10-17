"""Start, reopen and stop coding-agent sessions on this Mac.

* New sessions from the phone start as Claude background sessions
  (``claude --bg``): nothing pops up on the Mac, and ``claude attach`` opens one.
* Reopening a conversation (Continue on Mac, Resume) runs ``claude --resume``
  / ``codex resume`` in the terminal app it came from: VS Code through the
  Jarvis Terminal Bridge extension (in the same terminal when the stale
  process can be stopped first), iTerm or Terminal.app by AppleScript, and a
  new Terminal.app window for anything else.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Callable, Optional

_BG_ID_RE = re.compile(r"backgrounded\s*·\s*([0-9a-f]{6,})")
_PERMISSION_MODES = ("default", "acceptEdits", "plan", "auto", "bypassPermissions")


def _alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def _looks_like_model(name) -> bool:
    n = str(name or "").strip().lower()
    return n in ("opus", "sonnet", "haiku") or n.startswith("claude-")


class LocalRuntime:
    def __init__(self, *, run: Callable = subprocess.run, vscode=None,
                 kill: Callable = os.kill, alive: Callable = _alive, grace: float = 5.0,
                 claude_bin: str = "claude", codex_bin: str = "codex") -> None:
        self._run = run
        self._vscode = vscode
        self._kill = kill
        self._alive = alive
        self._grace = grace
        self._claude = claude_bin
        self._codex = codex_bin

    # ── new sessions ─────────────────────────────────────────────────────
    def ensure_trusted(self, cwd: str) -> None:
        cfg = os.environ.get("CLAUDE_CONFIG_DIR")
        path = Path(cfg) / ".claude.json" if cfg else Path.home() / ".claude.json"
        try:
            data = json.loads(path.read_text()) if path.exists() else {}
        except (OSError, ValueError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        entry = data.setdefault("projects", {}).setdefault(os.path.realpath(cwd), {})
        if entry.get("hasTrustDialogAccepted") is True:
            return
        entry["hasTrustDialogAccepted"] = True
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".claude.json.")
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=2)
        os.replace(tmp, path)

    def launch_bg(self, cwd: str, *, agent: str = "claude", model: Optional[str] = None,
                  permission_mode: Optional[str] = None, prompt: Optional[str] = None,
                  terminal: Optional[dict] = None) -> str:
        cwd = os.path.expanduser(cwd)
        os.makedirs(cwd, exist_ok=True)
        if agent == "codex":
            cmd = self._codex + ((" " + shlex.quote(prompt)) if prompt else "")
            self.open_in_terminal(cwd, cmd, terminal or {"term_program": "vscode"})
            return ""
        self.ensure_trusted(cwd)
        argv = [self._claude, "--bg"]
        if _looks_like_model(model):
            argv += ["--model", str(model)]
        if permission_mode in _PERMISSION_MODES:
            argv += ["--permission-mode", permission_mode]
        if prompt:
            argv.append(prompt)
        # Never a pipe: `claude --bg` leaves a daemon holding its stdout.
        with tempfile.TemporaryFile(mode="w+") as fh:
            out = self._run(argv, cwd=cwd, stdout=fh, stderr=subprocess.STDOUT, text=True,
                            stdin=subprocess.DEVNULL, timeout=60)
            fh.seek(0)
            text = fh.read()
        m = _BG_ID_RE.search(text)
        if getattr(out, "returncode", 1) != 0 or not m:
            raise RuntimeError(text.strip().splitlines()[0] if text.strip() else "claude --bg failed")
        return m.group(1)

    # ── reopening ────────────────────────────────────────────────────────
    def resume_command(self, agent: str, session_id: str) -> str:
        if agent == "codex":
            return f"{self._codex} resume {shlex.quote(session_id)}"
        return f"{self._claude} --resume {shlex.quote(session_id)}"

    def resume_in_terminal(self, agent: str, session_id: str, cwd: str,
                           terminal: Optional[dict] = None, stale_pid=None) -> str:
        cmd = self.resume_command(agent, session_id)
        terminal = terminal or {}
        if self._vscode is not None and str(terminal.get("term_program") or "").lower() == "vscode":
            shell = self._vscode.terminal_pid_for(int(stale_pid)) if stale_pid else None
            if shell:
                self.stop_pid(stale_pid)
                if self._vscode.send_text(shell, f"cd {shlex.quote(cwd)} && {cmd}"):
                    return "vscode"
            if self._vscode.run_in_terminal(cwd, cmd):
                return "vscode"
        if stale_pid:
            self.stop_pid(stale_pid)
        return self.open_in_terminal(cwd, cmd, terminal)

    def open_in_terminal(self, cwd: str, cmd: str, terminal: dict) -> str:
        line = f"cd {shlex.quote(cwd)} && {cmd}"
        if self._vscode is not None and str(terminal.get("term_program") or "").lower() == "vscode":
            if self._vscode.run_in_terminal(cwd, cmd):
                return "vscode"
        if terminal.get("iterm") or str(terminal.get("term_program") or "").lower() == "iterm.app":
            script = ['on run argv', 'tell application "iTerm2"', 'activate',
                      'set w to (create window with default profile)',
                      'tell current session of w to write text (item 1 of argv)',
                      'end tell', 'end run']
            if self._osascript(script, [line]) == 0:
                return "iterm"
        script = ['on run argv', 'tell application "Terminal"', 'activate',
                  'do script (item 1 of argv)', 'end tell', 'end run']
        self._osascript(script, [line])
        return "terminal"

    def _osascript(self, lines: list, args: list) -> int:
        argv = ["/usr/bin/osascript"]
        for ln in lines:
            argv += ["-e", ln]
        argv += list(args)
        try:
            out = self._run(argv, capture_output=True, timeout=15)
            return int(getattr(out, "returncode", 1) or 0)
        except (OSError, subprocess.SubprocessError):
            return 1

    # ── stopping ─────────────────────────────────────────────────────────
    def stop_pid(self, pid) -> None:
        try:
            pid = int(pid)
        except (TypeError, ValueError):
            return
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                self._kill(pid, sig)
            except OSError:
                return
            end = time.monotonic() + self._grace
            while time.monotonic() < end:
                if not self._alive(pid):
                    return
                time.sleep(0.05)

    def stop_bg(self, bg_id: str) -> None:
        with tempfile.TemporaryFile(mode="w+") as fh:
            self._run([self._claude, "stop", bg_id], stdout=fh, stderr=subprocess.STDOUT,
                      stdin=subprocess.DEVNULL, text=True, timeout=30)
