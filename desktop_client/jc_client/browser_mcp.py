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


class _BrowserMcp:
    """Owns a persistent local Playwright MCP ClientSession on a background
    asyncio loop. Lazily started; auto-restarts if the child dies."""

    def __init__(self) -> None:
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._thread: Optional[threading.Thread] = None
        self._session = None
        self._stop: Optional[asyncio.Event] = None
        self._ready = threading.Event()
        self._start_error: Optional[BaseException] = None
        self._lock = threading.Lock()

    # ── lifecycle ───────────────────────────────────────────────────────

    def _ensure_started(self) -> None:
        with self._lock:
            alive = (self._thread and self._thread.is_alive()
                     and self._session is not None)
            if alive:
                return
            self._session = None
            self._ready.clear()
            self._start_error = None
            self._thread = threading.Thread(
                target=self._run_loop, daemon=True, name="browser-mcp")
            self._thread.start()
        if not self._ready.wait(timeout=_READY_TIMEOUT + 10):
            raise RuntimeError("Playwright MCP did not start in time")
        if self._start_error is not None:
            raise RuntimeError(f"Playwright MCP failed to start: {self._start_error}")

    def _run_loop(self) -> None:
        loop = asyncio.new_event_loop()
        self._loop = loop
        asyncio.set_event_loop(loop)
        try:
            loop.run_until_complete(self._serve())
        except Exception as exc:  # noqa: BLE001
            self._start_error = exc
            self._ready.set()
        finally:
            try:
                loop.close()
            except Exception:
                pass

    async def _serve(self) -> None:
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client
        from jc_client.mcp_relay import find_npx, read_extension_token_from_chrome

        npx = find_npx() or "npx"
        env = dict(os.environ)
        bindir = os.path.dirname(npx) if os.path.sep in npx else ""
        if bindir and bindir not in env.get("PATH", "").split(os.pathsep):
            env["PATH"] = bindir + os.pathsep + env.get("PATH", "")
        token = read_extension_token_from_chrome()
        if token:
            env["PLAYWRIGHT_MCP_EXTENSION_TOKEN"] = token
        params = StdioServerParameters(
            command=npx,
            args=["@playwright/mcp@latest", "--extension", "--browser", "chrome"],
            env=env,
        )
        self._stop = asyncio.Event()
        try:
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    self._session = session
                    log.info("Playwright MCP (extension) ready for browser skills")
                    self._ready.set()
                    await self._stop.wait()  # keep the session alive
        except Exception as exc:  # noqa: BLE001
            self._start_error = exc
            self._ready.set()
        finally:
            self._session = None

    # ── public (sync, called from skill threads) ────────────────────────

    def call_tool(self, name: str, args: Optional[dict] = None,
                  timeout: float = _CALL_TIMEOUT) -> dict:
        """Run a Playwright MCP tool and return ``{"ok", "result"}``. Raises on
        start/dispatch failure (the skill surfaces it to the agent)."""
        self._ensure_started()
        fut = asyncio.run_coroutine_threadsafe(self._call(name, args or {}), self._loop)
        return fut.result(timeout=timeout)

    async def _call(self, name: str, args: dict) -> dict:
        result = await self._session.call_tool(name, args)
        text = "".join(getattr(c, "text", "") for c in (result.content or []))
        return {"ok": not bool(getattr(result, "isError", False)), "result": text}


_INSTANCE = _BrowserMcp()


def browser_mcp() -> "_BrowserMcp":
    return _INSTANCE
