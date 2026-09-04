"""A2: drive the user's real, visible Chrome via a LOCAL Playwright MCP, exposed
as device skills.

The Mac client runs ``npx @playwright/mcp --extension`` (connected to the user's
Chrome via the Playwright extension) and acts as an MCP *client* to it. The
``chrome_*`` skills in ``skills/browser.py`` call through this manager; results
go back to the server over the bridge's proven ``invoke_skill`` path — no
MCP-transport-over-the-bridge (which A1 couldn't make work reliably).

A dedicated asyncio loop in a background thread hosts the persistent
``ClientSession``; the sync skill functions submit calls to it.
"""

from __future__ import annotations

import asyncio
import logging
import os
import threading
from typing import Any, Optional

log = logging.getLogger(__name__)

_READY_TIMEOUT = 60.0   # cold `npx @playwright/mcp` + browser attach
_CALL_TIMEOUT = 90.0    # generous for slow page loads
# plan 3.5: cap how long a caller blocks on a cold start. The agent's
# per-skill watchdog is 20s (service.py _SKILL_TIMEOUT_S) — without this, a
# genuine 60s npx cold start would eat the whole watchdog and the agent would
# see a bare timeout instead of a clear "still warming, retry" signal. The
# supervisor keeps warming in the background regardless of this budget.
_COLD_START_BUDGET = 8.0
# plan 3.5: backoff schedule (seconds) for restarting a child that keeps
# dying — same shape as service.py's reconnect backoff.
_RESTART_BACKOFF = [1, 2, 4, 8, 16, 32, 60]

# A2's biggest cost: an accessibility snapshot of a content-heavy page (a long
# Wikipedia article has ~4k links) is hundreds of KB. Returned RAW, ONE snapshot
# dumps 50-130k tokens into the agent's context, and several across a task
# compound — one real run hit 325k input tokens. Cap snapshot-bearing results
# the same structure-aware way the server's own browser tool does
# (tools/browser_tool.py `_truncate_snapshot`), but with a higher default ceiling
# since this device path has no LLM-summarize fallback. 0 disables the cap.
_SNAPSHOT_MAX_CHARS_DEFAULT = 20000


def _snapshot_max_chars() -> int:
    raw = os.environ.get("JC_BROWSER_SNAPSHOT_MAX_CHARS")
    if raw is None:
        return _SNAPSHOT_MAX_CHARS_DEFAULT
    try:
        return max(0, int(raw))
    except (TypeError, ValueError):
        return _SNAPSHOT_MAX_CHARS_DEFAULT


def _truncate_snapshot(text: str, max_chars: Optional[int] = None) -> str:
    """Structure-aware truncation of a Playwright result so a giant accessibility
    tree doesn't blow up the agent's context. Cuts at newline boundaries (never
    splits a tree node mid-line) and appends a note telling the agent how much
    was dropped + how to recover it. Returns ``text`` unchanged when within
    budget, or when the cap is disabled (``<= 0``)."""
    cap = _snapshot_max_chars() if max_chars is None else max_chars
    if cap <= 0 or len(text) <= cap:
        return text
    lines = text.split("\n")
    kept: list[str] = []
    chars = 0
    for line in lines:
        if chars + len(line) + 1 > cap - 260:  # reserve room for the note
            break
        kept.append(line)
        chars += len(line) + 1
    dropped = len(lines) - len(kept)
    kept.append(
        f"\n[... {dropped} more lines truncated to save context "
        f"({len(text)} chars total). Scroll or click into the relevant section "
        f"for a smaller snapshot, or raise JC_BROWSER_SNAPSHOT_MAX_CHARS.]"
    )
    return "\n".join(kept)


def _config_extension_token() -> Optional[str]:
    """Configured Playwright extension token — stable fallback when the live
    read from Chrome's leveldb fails (it gets compacted into .ldb)."""
    try:
        import yaml
        from jc_client.logger import state_dir
        raw = yaml.safe_load((state_dir() / "config.yaml").read_text()) or {}
        tok = raw.get("playwright_extension_token")
        return str(tok) if tok else None
    except Exception:
        return None


class _BrowserMcp:
    """Owns a persistent local Playwright MCP ClientSession on a background
    asyncio loop. Lazily started; a supervisor thread watches the child and
    restarts + re-warms it in the background if it dies, with backoff if it
    keeps dying."""

    def __init__(self) -> None:
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._supervisor_thread: Optional[threading.Thread] = None
        self._session = None
        self._stop: Optional[asyncio.Event] = None
        # Set when the CURRENT start attempt has reached a terminal state for
        # this attempt (warm, or failed) — cleared at the start of each
        # attempt. This is what _ensure_started's cold-start budget waits on.
        self._ready = threading.Event()
        self._start_error: Optional[BaseException] = None
        self._lock = threading.Lock()
        self._explicit_stop = threading.Event()
        self._restart_backoff_idx = 0
        # Did the CURRENT attempt make it to "warm" before _serve() returned?
        # Used to reset the backoff counter — a child that dies after being
        # healthy for a while shouldn't inherit a long backoff from a
        # previous crash loop.
        self._became_ready = False

    # ── lifecycle ───────────────────────────────────────────────────────

    def is_warm(self) -> bool:
        """True once the child + extension handshake is done and a call can
        be dispatched immediately (no cold-start wait)."""
        return self._session is not None

    def _ensure_supervisor(self) -> None:
        """Start the background supervisor thread if it isn't already
        running. Idempotent — safe to call from every entry point."""
        with self._lock:
            if self._supervisor_thread and self._supervisor_thread.is_alive():
                return
            self._ready.clear()
            self._explicit_stop.clear()
            self._supervisor_thread = threading.Thread(
                target=self._supervisor_loop, daemon=True, name="browser-mcp")
            self._supervisor_thread.start()

    def _ensure_started(self) -> Optional[dict]:
        """Make sure the supervisor is running and, only for a cold start,
        wait a bounded budget for it to come up. Returns ``None`` once warm
        (caller may proceed) or an error dict to hand straight back to the
        agent — the supervisor keeps warming in the background either way,
        so a retry shortly after usually succeeds."""
        self._ensure_supervisor()
        if self.is_warm():
            return None
        self._ready.wait(timeout=_COLD_START_BUDGET)
        if self.is_warm():
            return None
        return {"ok": False, "error": "browser warming up, retry"}

    def _supervisor_loop(self) -> None:
        """Own the child's whole lifetime. Each iteration runs ``_serve()``
        to completion (it only returns when the child dies, fails to start,
        or we're told to stop); if that wasn't an explicit stop, restart
        after a backoff delay — forever, in the background, so nothing has
        to notice unless it happens to be mid-call when the child dies."""
        while not self._explicit_stop.is_set():
            self._start_error = None
            self._became_ready = False
            loop = asyncio.new_event_loop()
            self._loop = loop
            asyncio.set_event_loop(loop)
            try:
                loop.run_until_complete(self._serve())
            except Exception as exc:  # noqa: BLE001
                self._start_error = exc
            finally:
                try:
                    loop.close()
                except Exception:
                    pass
            self._session = None
            self._ready.set()
            if self._became_ready:
                self._restart_backoff_idx = 0
            if self._explicit_stop.is_set():
                return
            delay = _RESTART_BACKOFF[min(self._restart_backoff_idx, len(_RESTART_BACKOFF) - 1)]
            self._restart_backoff_idx += 1
            log.warning(
                "Playwright MCP child %s — restarting in %ss",
                f"failed to start ({self._start_error})" if self._start_error else "exited",
                delay,
            )
            self._ready.clear()
            if self._explicit_stop.wait(delay):
                return

    async def _serve(self) -> None:
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client
        from jc_client.mcp_relay import (
            find_npx, read_extension_token_from_chrome, PLAYWRIGHT_MCP_SPEC)

        npx = find_npx() or "npx"
        env = dict(os.environ)
        bindir = os.path.dirname(npx) if os.path.sep in npx else ""
        if bindir and bindir not in env.get("PATH", "").split(os.pathsep):
            env["PATH"] = bindir + os.pathsep + env.get("PATH", "")
        # Live read first (handles regeneration); fall back to the configured
        # token, which survives Chrome's leveldb compaction. Without a token the
        # extension shows an allow-dialog the daemon can't click.
        token = read_extension_token_from_chrome() or _config_extension_token()
        if token:
            env["PLAYWRIGHT_MCP_EXTENSION_TOKEN"] = token
        else:
            log.warning("no Playwright extension token — the extension will "
                        "show an allow-dialog; set playwright_extension_token in config")
        params = StdioServerParameters(
            command=npx,
            # Pinned (was `@latest`) — see PLAYWRIGHT_MCP_SPEC: schemas drift
            # between releases and the chrome_* skills must match the pinned one.
            args=[PLAYWRIGHT_MCP_SPEC, "--extension", "--browser", "chrome"],
            env=env,
        )
        self._stop = asyncio.Event()
        try:
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    self._session = session
                    self._became_ready = True
                    log.info("Playwright MCP (extension) ready for browser skills")
                    self._ready.set()
                    await self._stop.wait()  # keep the session alive
        except Exception as exc:  # noqa: BLE001
            self._start_error = exc
            self._ready.set()
        finally:
            self._session = None

    def start(self) -> bool:
        """Pre-warm the Playwright MCP + extension connection so the first
        browser action isn't cold. Best-effort; returns True if warm within
        the cold-start budget — the supervisor keeps trying in the
        background regardless of what this call returns."""
        err = self._ensure_started()
        if err is not None:
            log.info("browser MCP warm-start still pending: %s", err.get("error"))
            return False
        return True

    # ── public (sync, called from skill threads) ────────────────────────

    def call_tool(self, name: str, args: Optional[dict] = None,
                  timeout: float = _CALL_TIMEOUT) -> dict:
        """Run a Playwright MCP tool and return ``{"ok", "result"}``. If the
        child is cold (or mid-restart) this returns a ``{"ok": false, ...}``
        warm-up notice instead of blocking — the agent can retry shortly."""
        warm_err = self._ensure_started()
        if warm_err is not None:
            return warm_err
        loop = self._loop
        fut = asyncio.run_coroutine_threadsafe(self._call(name, args or {}), loop)
        return fut.result(timeout=timeout)

    async def _call(self, name: str, args: dict) -> dict:
        result = await self._session.call_tool(name, args)
        text = "".join(getattr(c, "text", "") for c in (result.content or []))
        return {"ok": not bool(getattr(result, "isError", False)),
                "result": _truncate_snapshot(text)}


_INSTANCE = _BrowserMcp()


def browser_mcp() -> "_BrowserMcp":
    return _INSTANCE
