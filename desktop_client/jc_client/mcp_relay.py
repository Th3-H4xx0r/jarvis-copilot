"""Desktop side of the MCP-frame relay (Phase 2, 2c).

The server's MCP host opens a relay (``mcp_open``); we spawn a local Playwright
MCP as a stdio child and become a DUMB PIPE between the bridge and that child:

  - child stdout line (one JSON-RPC message) → ``mcp_frame`` to the server
  - inbound ``mcp_frame`` → written to the child's stdin (+ newline)

No MCP SDK is needed here — we never parse the frames, just shuttle text. The
server side (``tools/mcp_relay_transport.py``) owns the MCP ``ClientSession``.
"""

from __future__ import annotations

import glob
import json
import logging
import os
import shutil
import subprocess
import threading
from typing import Callable, Optional

log = logging.getLogger(__name__)

# Browsers Playwright MCP's --browser flag accepts. The server only influences
# the browser choice (a safe enum); it can NOT dictate the profile path.
_ALLOWED_BROWSERS = {"chrome", "msedge", "chromium", "firefox", "webkit"}
_DEFAULT_BROWSER = "chrome"

# Pin the Playwright MCP version (not `@latest`): its tool schemas drift between
# releases — e.g. 0.0.75 takes the snapshot ref as `target` where older builds
# used `ref`, and the hand-written chrome_* skills (skills/browser.py) must match.
# Single source of truth, shared by the A1 relay and the A2 browser_mcp child.
PLAYWRIGHT_MCP_SPEC = "@playwright/mcp@0.0.75"


def _profile_dir() -> str:
    from jc_client.logger import state_dir
    p = state_dir() / "playwright-profile"
    p.mkdir(parents=True, exist_ok=True)
    return str(p)


# The published Playwright MCP Chrome extension's (stable) ID. Its status page
# stores the connection token in localStorage under key "auth-token", which
# Chrome persists in <profile>/Local Storage/leveldb as plaintext — so we can
# auto-discover it and never make the user copy/paste a token.
PLAYWRIGHT_EXTENSION_ID = "mmlmfjhmonkocbjadbfplnigmagldckm"


def _chrome_localstorage_globs() -> list[str]:
    """Glob patterns for Chrome's Local Storage leveldb across OSes/profiles."""
    import sys
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        roots = [os.path.join(home, "Library/Application Support/Google/Chrome")]
    elif sys.platform.startswith("win"):
        roots = [os.path.join(os.environ.get("LOCALAPPDATA", ""), "Google/Chrome/User Data")]
    else:
        roots = [os.path.join(home, ".config/google-chrome"),
                 os.path.join(home, ".config/chromium")]
    return [os.path.join(r, "*", "Local Storage", "leveldb", "*") for r in roots if r]


def read_extension_token_from_chrome(ext_id: str = PLAYWRIGHT_EXTENSION_ID,
                                     globs: Optional[list[str]] = None) -> Optional[str]:
    """Auto-discover the Playwright Extension's connection token from Chrome's
    on-disk localStorage, so the user never copy/pastes it. Returns the most
    recently written token, or None if not found / Chrome not present."""
    import re
    pat = re.compile(
        rb"_chrome-extension://" + re.escape(ext_id.encode())
        + rb"\x00\x01auth-token.{0,6}?([A-Za-z0-9_-]{24,})",
        re.S,
    )
    found: Optional[str] = None
    for pattern in (globs if globs is not None else _chrome_localstorage_globs()):
        for path in glob.glob(pattern):
            try:
                data = open(path, "rb").read()
            except Exception:
                continue
            for m in pat.finditer(data):
                found = m.group(1).decode()  # last write wins (handles regen)
    return found


def find_npx() -> Optional[str]:
    """Locate the ``npx`` binary, resilient to launchd's minimal PATH.

    A LaunchAgent daemon doesn't inherit the user's shell PATH, so an
    nvm/homebrew npx isn't on ``PATH`` even though it's installed. Check PATH
    first, then common install locations (newest nvm node wins)."""
    p = shutil.which("npx")
    if p:
        return p
    home = os.path.expanduser("~")
    candidates = sorted(
        glob.glob(os.path.join(home, ".nvm/versions/node/*/bin/npx")), reverse=True
    ) + ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"]
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def build_playwright_command(meta: Optional[dict], profile_dir: str,
                             extension: bool = False) -> list[str]:
    """Build the ``npx @playwright/mcp`` argv. Only ``meta.browser`` (a safe
    enum) is honored from the server; the profile dir is chosen locally. Uses a
    resolved npx path so it works under launchd's minimal PATH.

    ``extension=True`` (a desktop-local choice) connects to the user's ALREADY-
    RUNNING Chrome via the Playwright Extension — real profile, real session, a
    visible window the user already has — instead of launching a separate
    headed-but-background profile. No ``--user-data-dir`` in that mode.
    """
    meta = meta if isinstance(meta, dict) else {}
    browser = str(meta.get("browser") or _DEFAULT_BROWSER).strip().lower()
    if browser not in _ALLOWED_BROWSERS:
        browser = _DEFAULT_BROWSER
    npx = find_npx() or "npx"
    if extension:
        return [npx, PLAYWRIGHT_MCP_SPEC, "--extension", "--browser", browser]
    return [
        npx, PLAYWRIGHT_MCP_SPEC,
        "--browser", browser,
        "--user-data-dir", profile_dir,
    ]


class McpRelayManager:
    """Owns the per-session Playwright MCP child processes for one bridge
    connection. Thread-safe; ``send`` is the connection's text-sender."""

    def __init__(self, send: Callable[[str], None], *,
                 profile_dir: Optional[str] = None,
                 spawn: Optional[Callable[..., subprocess.Popen]] = None,
                 command_builder: Callable[..., list[str]] = build_playwright_command,
                 extension: bool = False,
                 extension_token: Optional[str] = None,
                 token_reader: Optional[Callable[[], Optional[str]]] = None):
        self._send = send
        self._profile_dir = profile_dir or _profile_dir()
        self._spawn = spawn or _default_spawn
        self._build = command_builder
        self._extension = extension
        self._extension_token = extension_token  # explicit fallback / override
        self._token_reader = token_reader or read_extension_token_from_chrome
        self._procs: dict[str, subprocess.Popen] = {}
        self._lock = threading.Lock()

    # ── bridge frame handlers ───────────────────────────────────────────

    def handle_open(self, session: str, meta: Optional[dict]) -> None:
        if not session:
            return
        cmd = self._build(meta, self._profile_dir, self._extension)
        extra_env = None
        if self._extension:
            # Auto-connect the --extension server to the user's Chrome without
            # the interactive "Connect" dialog (impossible from a daemon).
            # Prefer the live token read from Chrome (handles regeneration);
            # fall back to an explicitly-configured token.
            token = None
            try:
                token = self._token_reader()
            except Exception as exc:
                log.debug("extension token auto-read failed: %s", exc)
            token = token or self._extension_token
            if token:
                extra_env = {"PLAYWRIGHT_MCP_EXTENSION_TOKEN": token}
            else:
                log.warning("extension mode but no Playwright token found — "
                            "install + open the Playwright extension in Chrome")
        try:
            proc = self._spawn(cmd, extra_env)
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


def _default_spawn(cmd: list[str], extra_env: Optional[dict] = None) -> subprocess.Popen:
    # Ensure node (next to npx) is on PATH for the child, since launchd's PATH
    # is minimal and npx shells out to node.
    env = dict(os.environ)
    bindir = os.path.dirname(cmd[0]) if cmd and os.path.sep in cmd[0] else ""
    if bindir and bindir not in env.get("PATH", "").split(os.pathsep):
        env["PATH"] = bindir + os.pathsep + env.get("PATH", "")
    if extra_env:
        env.update(extra_env)
    return subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
        env=env,
    )


def _terminate(proc: subprocess.Popen) -> None:
    try:
        proc.terminate()
    except Exception:
        pass
