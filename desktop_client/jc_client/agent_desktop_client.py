"""One long-lived ``agent-desktop mcp`` child for computer control.

Started on first use, one request at a time (jc-client already makes one move at a time), and
killed + restarted when a call hangs past its timeout or the child dies — so a stuck accessibility
read never blocks the next look. Each call returns agent-desktop's own JSON envelope
(``{"ok", "data"}`` / ``{"ok": False, "error": {"code", "message", …}}``). No session, no trace.
"""
from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Optional

from jc_client.agent_desktop_install import installed_path
from jc_client.logger import state_dir

_PROTOCOL = "2025-06-18"
_TIMEOUT = {"ok": False, "error": {"code": "CLIENT_TIMEOUT", "message": "agent-desktop didn't answer"}}
_DIED = {"ok": False, "error": {"code": "CLIENT_DIED", "message": "agent-desktop stopped"}}
_BAD = {"ok": False, "error": {"code": "BAD_REPLY", "message": "agent-desktop sent an unexpected reply"}}


class _Timeout(Exception):
    pass


class _Died(Exception):
    pass


class AgentDesktop:
    def __init__(self, argv: list, home: str) -> None:
        self.argv = list(argv)
        self.home = home
        self._proc: Optional[subprocess.Popen] = None
        self._lines: Optional[queue.Queue] = None
        self._id = 0
        self._lock = threading.Lock()

    # ── the child ──────────────────────────────────────────────────────────
    def _start(self, deadline: float) -> None:
        os.makedirs(self.home, exist_ok=True)
        if sys.platform != "win32":
            os.chmod(self.home, 0o700)  # agent-desktop refuses a state root others can read
        env = {k: v for k, v in os.environ.items() if not k.startswith("AGENT_DESKTOP")}
        env["AGENT_DESKTOP_HOME"] = self.home
        extra = {"creationflags": 0x08000000} if sys.platform == "win32" else {}  # CREATE_NO_WINDOW
        proc = subprocess.Popen(self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, encoding="utf-8", bufsize=1,
                                env=env, **extra)
        lines: queue.Queue = queue.Queue()

        def read() -> None:
            for line in proc.stdout:
                lines.put(line)
            lines.put(None)

        threading.Thread(target=read, name="agent-desktop-reader", daemon=True).start()
        self._proc, self._lines = proc, lines
        self._request("initialize", {"protocolVersion": _PROTOCOL, "capabilities": {},
                                     "clientInfo": {"name": "jc-client", "version": "1"}}, deadline)
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _kill(self) -> None:
        proc, self._proc = self._proc, None
        if proc is not None and proc.poll() is None:
            try:
                proc.kill()
            except OSError:
                pass

    def _send(self, msg: dict) -> None:
        try:
            self._proc.stdin.write(json.dumps(msg) + "\n")
            self._proc.stdin.flush()
        except (OSError, ValueError) as exc:
            raise _Died() from exc

    def _request(self, method: str, params: dict, deadline: float) -> dict:
        self._id += 1
        want = self._id
        self._send({"jsonrpc": "2.0", "id": want, "method": method, "params": params})
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise _Timeout()
            try:
                line = self._lines.get(timeout=left)
            except queue.Empty:
                raise _Timeout() from None
            if line is None:
                raise _Died()
            try:
                msg = json.loads(line)
            except ValueError:
                continue  # not a protocol line
            if isinstance(msg, dict) and msg.get("id") == want:
                return msg

    # ── calls ──────────────────────────────────────────────────────────────
    def call(self, tool: str, args: dict, timeout: float = 8.0) -> dict:
        """Run one agent-desktop tool; its envelope, or a CLIENT_* error (child restarted next time)."""
        with self._lock:
            deadline = time.monotonic() + timeout
            for attempt in (1, 2):
                fresh = self._proc is None or self._proc.poll() is not None
                try:
                    if fresh:
                        self._kill()
                        self._start(deadline)
                    msg = self._request("tools/call", {"name": tool, "arguments": args}, deadline)
                    break
                except _Timeout:
                    self._kill()
                    return dict(_TIMEOUT)
                except (_Died, OSError):
                    self._kill()
                    if fresh or attempt == 2:
                        return dict(_DIED)
                    # It died between calls: one fresh child for this call.
            if "error" in msg:
                return {"ok": False, "error": {"code": "MCP_ERROR",
                                               "message": str((msg.get("error") or {}).get("message") or "")}}
            content = (msg.get("result") or {}).get("content") or [{}]
            try:
                envelope = json.loads(content[0].get("text") or "")
            except (ValueError, AttributeError):
                return dict(_BAD)
            return envelope if isinstance(envelope, dict) else dict(_BAD)

    def close(self) -> None:
        with self._lock:
            self._kill()


_client: Optional[AgentDesktop] = None
_client_lock = threading.Lock()


def get() -> Optional[AgentDesktop]:
    """The shared child for this machine, or None when agent-desktop isn't installed."""
    global _client
    with _client_lock:
        if _client is not None:
            return _client
        path = installed_path(str(state_dir()))
        if not path:
            return None
        _client = AgentDesktop([path, "mcp"], str(Path(state_dir()) / "agent-desktop-home"))
        return _client
