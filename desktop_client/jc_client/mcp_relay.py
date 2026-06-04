"""Desktop side of the MCP-frame relay (Phase 2, 2c).

The server's MCP host opens a relay (``mcp_open``); we spawn a local Playwright
MCP as a stdio child and become a DUMB PIPE between the bridge and that child:

  - child stdout line (one JSON-RPC message) → ``mcp_frame`` to the server
  - inbound ``mcp_frame`` → written to the child's stdin (+ newline)

No MCP SDK is needed here — we never parse the frames, just shuttle text. The
server side (``tools/mcp_relay_transport.py``) owns the MCP ``ClientSession``.
"""

from __future__ import annotations

import json
import logging
import subprocess
import threading
from typing import Callable, Optional

log = logging.getLogger(__name__)

# Browsers Playwright MCP's --browser flag accepts. The server only influences
# the browser choice (a safe enum); it can NOT dictate the profile path.
_ALLOWED_BROWSERS = {"chrome", "msedge", "chromium", "firefox", "webkit"}
_DEFAULT_BROWSER = "chrome"


def _profile_dir() -> str:
    from jc_client.logger import state_dir
    p = state_dir() / "playwright-profile"
    p.mkdir(parents=True, exist_ok=True)
    return str(p)


def build_playwright_command(meta: Optional[dict], profile_dir: str) -> list[str]:
    """Build the ``npx @playwright/mcp`` argv. Only ``meta.browser`` (a safe
    enum) is honored from the server; the profile dir is chosen locally."""
    meta = meta if isinstance(meta, dict) else {}
    browser = str(meta.get("browser") or _DEFAULT_BROWSER).strip().lower()
    if browser not in _ALLOWED_BROWSERS:
        browser = _DEFAULT_BROWSER
    return [
        "npx", "@playwright/mcp@latest",
        "--browser", browser,
        "--user-data-dir", profile_dir,
    ]


class McpRelayManager:
    """Owns the per-session Playwright MCP child processes for one bridge
    connection. Thread-safe; ``send`` is the connection's text-sender."""

    def __init__(self, send: Callable[[str], None], *,
                 profile_dir: Optional[str] = None,
                 spawn: Optional[Callable[[list[str]], subprocess.Popen]] = None,
                 command_builder: Callable[[Optional[dict], str], list[str]] = build_playwright_command):
        self._send = send
        self._profile_dir = profile_dir or _profile_dir()
        self._spawn = spawn or _default_spawn
        self._build = command_builder
        self._procs: dict[str, subprocess.Popen] = {}
        self._lock = threading.Lock()

    # ── bridge frame handlers ───────────────────────────────────────────

    def handle_open(self, session: str, meta: Optional[dict]) -> None:
        if not session:
            return
        cmd = self._build(meta, self._profile_dir)
        try:
            proc = self._spawn(cmd)
        except Exception as exc:  # noqa: BLE001
            log.warning("playwright spawn failed: %s", exc)
            self._emit("mcp_error", session, error=f"spawn failed: {exc}")
            return
        with self._lock:
            self._procs[session] = proc
        threading.Thread(
            target=self._pump_stdout, args=(session, proc),
            daemon=True, name=f"mcp-relay-{session[:8]}",
        ).start()
        self._emit("mcp_ready", session)
        log.info("mcp relay session %s started (%s)", session, cmd[1])

    def handle_frame(self, session: str, data: str) -> None:
        with self._lock:
            proc = self._procs.get(session)
        if not proc or not proc.stdin:
            return
        try:
            proc.stdin.write((data or "") + "\n")
            proc.stdin.flush()
        except Exception as exc:  # noqa: BLE001 — broken pipe → child died
            log.debug("mcp relay stdin write failed for %s: %s", session, exc)

    def handle_close(self, session: str) -> None:
        with self._lock:
            proc = self._procs.pop(session, None)
        if proc:
            _terminate(proc)
            log.info("mcp relay session %s closed", session)

    def shutdown_all(self) -> None:
        with self._lock:
            procs = list(self._procs.items())
            self._procs.clear()
        for _sid, proc in procs:
            _terminate(proc)

    # ── internals ───────────────────────────────────────────────────────

    def _pump_stdout(self, session: str, proc: subprocess.Popen) -> None:
        try:
            for line in proc.stdout:  # text-mode, line-buffered
                line = line.rstrip("\n")
                if not line:
                    continue
                self._emit("mcp_frame", session, data=line)
        except Exception as exc:  # noqa: BLE001
            log.debug("mcp relay stdout pump ended for %s: %s", session, exc)
        finally:
            with self._lock:
                still = self._procs.pop(session, None)
            if still is not None:
                # Child exited on its own — tell the server the session is gone.
                self._emit("mcp_closed", session)

    def _emit(self, msg_type: str, session: str, **fields) -> None:
        try:
            self._send(json.dumps({"type": msg_type, "session": session, **fields}))
        except Exception as exc:  # noqa: BLE001 — connection closed
            log.debug("mcp relay emit %s failed: %s", msg_type, exc)


def _default_spawn(cmd: list[str]) -> subprocess.Popen:
    return subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )


def _terminate(proc: subprocess.Popen) -> None:
    try:
        proc.terminate()
    except Exception:
        pass
