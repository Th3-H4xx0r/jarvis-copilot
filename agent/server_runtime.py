"""Run Claude Code sessions on the server as Claude's own background sessions.

No tmux. ``claude --bg`` starts (or ``--resume <id>`` continues) a session
detached; ``claude agents --json`` lists what runs; ``claude stop`` ends it.
A message is delivered by opening ``claude attach <id>`` in a pseudo-terminal
for a moment and pasting it in (bracketed paste, then Enter); the session
keeps running after the attach goes away. Facts this rests on (spike,
2026-10-17, Claude Code 2.1.302):

* ``--bg`` refuses a folder that isn't trusted, so ``ensure_trusted`` marks
  it in ``~/.claude.json`` first.
* ``--bg --resume <id>`` on a conversation that started interactively keeps
  the same id, even with flags. On one that STARTED as ``--bg``, any flag
  makes a copy under a new id, so those resume with no flags (``bg_origin``).
"""
from __future__ import annotations

import json
import os
import re
import select
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Callable, Optional

_BG_ID_RE = re.compile(r"backgrounded\s*·\s*([0-9a-f]{6,})")
_PERMISSION_MODES = ("default", "acceptEdits", "plan", "auto", "bypassPermissions")
_SCRUB = ("ANTHROPIC_API_KEY", "ANTHROPIC_TOKEN", "ANTHROPIC_AUTH_TOKEN",
          "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
          "CLAUDE_CODE_ENTRYPOINT", "CLAUDECODE")


class DeliveryError(Exception):
    """A message could not be put into the session; ``str()`` says why."""


def _env() -> dict:
    try:
        from agent.claude_code_client import _build_subprocess_env
        env = _build_subprocess_env()
    except Exception:  # noqa: BLE001
        env = os.environ.copy()
    for k in _SCRUB:
        env.pop(k, None)
    return env


def _allowed_model(name: Optional[str]) -> bool:
    try:
        from agent.claude_code_client import _looks_like_claude_model
        return bool(name) and _looks_like_claude_model(name)
    except Exception:  # noqa: BLE001
        n = (name or "").strip().lower()
        return n in ("opus", "sonnet", "haiku") or n.startswith("claude-")


class _Pty:
    """A child process on a pseudo-terminal (POSIX)."""

    def __init__(self, argv: list, env: dict) -> None:
        import pty
        import fcntl
        import struct
        import termios
        self.pid, self.fd = pty.fork()
        if self.pid == 0:  # child
            try:
                os.execvpe(argv[0], argv, env)
            finally:
                os._exit(127)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

    def read_some(self, timeout: float) -> bytes:
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return b""
        try:
            return os.read(self.fd, 65536)
        except OSError:
            return b""

    def write(self, data: bytes) -> None:
        os.write(self.fd, data)

    def close(self) -> None:
        for sig, wait in ((signal.SIGTERM, 2.0), (signal.SIGKILL, 2.0)):
            try:
                os.kill(self.pid, sig)
            except OSError:
                break
            end = time.monotonic() + wait
            while time.monotonic() < end:
                try:
                    if os.waitpid(self.pid, os.WNOHANG)[0]:
                        end = 0
                        break
                except OSError:
                    end = 0
                    break
                time.sleep(0.05)
            if end == 0:
                break
        try:
            os.close(self.fd)
        except OSError:
            pass


class ClaudeRuntime:
    def __init__(self, *, run: Callable = subprocess.run,
                 pty_factory: Optional[Callable[[list], object]] = None,
                 binary: str = "claude", settle: float = 0.4) -> None:
        self._run = run
        self._pty = pty_factory or (lambda argv: _Pty(argv, _env()))
        self._bin = binary
        self._settle = settle

    # ── trust ────────────────────────────────────────────────────────────
    def _config_path(self) -> Path:
        cfg = os.environ.get("CLAUDE_CONFIG_DIR")
        return Path(cfg) / ".claude.json" if cfg else Path.home() / ".claude.json"

    def ensure_trusted(self, cwd: str) -> None:
        path = self._config_path()
        try:
            data = json.loads(path.read_text()) if path.exists() else {}
        except (OSError, ValueError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        projects = data.setdefault("projects", {})
        entry = projects.setdefault(os.path.realpath(cwd), {})
        if entry.get("hasTrustDialogAccepted") is True:
            return
        entry["hasTrustDialogAccepted"] = True
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".claude.json.")
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=2)
        os.replace(tmp, path)

    # ── lifecycle ────────────────────────────────────────────────────────
    def start(self, cwd: str, *, prompt: Optional[str] = None, model: Optional[str] = None,
              permission_mode: Optional[str] = None, resume_session_id: Optional[str] = None,
              bg_origin: bool = False, mcp_config: Optional[str] = None) -> str:
        argv = [self._bin, "--bg"]
        env = _env()
        if not (resume_session_id and bg_origin):
            if _allowed_model(model):
                argv += ["--model", str(model)]
            if permission_mode in _PERMISSION_MODES:
                argv += ["--permission-mode", permission_mode]
                if permission_mode == "bypassPermissions" and os.geteuid() == 0:
                    env["IS_SANDBOX"] = "1"
            if mcp_config:
                argv += ["--mcp-config", mcp_config, "--strict-mcp-config"]
        if resume_session_id:
            argv += ["--resume", resume_session_id]
        if prompt and not (resume_session_id and bg_origin):
            argv.append(prompt)
        rc, text = self._call(argv, cwd=cwd, env=env, timeout=60)
        m = _BG_ID_RE.search(text)
        if rc != 0 or not m:
            raise RuntimeError(text.strip().splitlines()[0] if text.strip() else
                               f"claude --bg exited {rc}")
        return m.group(1)

    def stop(self, bg_id: str) -> None:
        self._call([self._bin, "stop", bg_id], timeout=30)

    def _call(self, argv: list, *, cwd: Optional[str] = None, env: Optional[dict] = None,
              timeout: float = 30) -> tuple:
        """Run a claude command; (returncode, output). Never through a pipe:
        `claude --bg` leaves a daemon holding the stdout it was given, so a pipe
        never reaches EOF and the call would hang forever (seen live)."""
        with tempfile.TemporaryFile(mode="w+") as fh:
            try:
                out = self._run(argv, cwd=cwd, env=env if env is not None else _env(),
                                stdout=fh, stderr=subprocess.STDOUT, text=True,
                                timeout=timeout, stdin=subprocess.DEVNULL)
            except (OSError, subprocess.SubprocessError) as exc:
                return 1, str(exc)
            fh.seek(0)
            return out.returncode, fh.read()

    def attach_argv(self, bg_id: str) -> list:
        return [self._bin, "attach", bg_id]

    def send(self, bg_id: str, text: str, timeout: float = 8.0) -> None:
        try:
            term = self._pty(self.attach_argv(bg_id))
        except OSError as exc:
            raise DeliveryError(f"couldn't open the session: {exc}") from exc
        try:
            deadline = time.monotonic() + timeout
            opened = False
            while time.monotonic() < deadline:
                if term.read_some(min(0.2, max(0.0, deadline - time.monotonic()))):
                    opened = True
                    break
            if not opened:
                raise DeliveryError("the session didn't open")
            time.sleep(self._settle)
            term.write(b"\x1b[200~" + text.encode("utf-8") + b"\x1b[201~")
            time.sleep(self._settle)
            term.write(b"\r")
            time.sleep(self._settle)
        finally:
            term.close()

    # ── listing ──────────────────────────────────────────────────────────
    def roster(self) -> list:
        rc, text = self._call([self._bin, "agents", "--json"], timeout=15)
        try:
            items = json.loads(text or "[]")
        except ValueError:
            return []
        entries = []
        for s in items if isinstance(items, list) else []:
            if not isinstance(s, dict) or not s.get("sessionId"):
                continue
            bg = s.get("kind") == "background"
            entries.append({"agent": "claude", "session_id": s["sessionId"],
                            "kind": s.get("kind") or "interactive",
                            "bg_id": s.get("id") if bg else None, "cwd": s.get("cwd") or "",
                            "name": s.get("name") or "", "status": s.get("status") or "",
                            "pid": s.get("pid")})
        return entries
