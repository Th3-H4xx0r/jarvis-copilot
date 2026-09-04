"""Tests for browser_mcp's supervised restart/backoff (plan 3.5).

The Playwright MCP child is monitored by a background supervisor thread: if
``_serve()`` ever returns (child died, or failed to start), the supervisor
restarts it with backoff. ``_ensure_started`` caps how long a caller blocks
on a cold start so the agent's per-skill watchdog isn't eaten by a slow
`npx` start.

No real `npx @playwright/mcp` child is spawned here — ``_serve`` is
monkeypatched per-test to simulate a fake child's lifecycle.

Run from the ``desktop_client`` directory:
    python3 -m pytest jc_client/test_browser_mcp_restart.py -q
"""
from __future__ import annotations

import asyncio
import logging
import time

import pytest

from jc_client import browser_mcp as bm


def _mgr() -> bm._BrowserMcp:
    """Fresh, un-started instance per test (never touch the module
    singleton — it would leak a real supervisor thread across tests)."""
    return bm._BrowserMcp()


def _wait_until(predicate, timeout=2.0, interval=0.01) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def test_is_warm_false_before_anything_starts():
    mgr = _mgr()
    assert mgr.is_warm() is False


def test_ensure_started_returns_none_once_warm(monkeypatch):
    mgr = _mgr()

    async def fake_serve():
        mgr._session = object()
        mgr._became_ready = True
        mgr._ready.set()
        stop = asyncio.Event()
        await stop.wait()  # stay "alive" for the rest of the test

    mgr._serve = fake_serve

    assert mgr._ensure_started() is None
    assert mgr.is_warm() is True


def test_ensure_started_returns_warming_dict_within_cold_start_budget(monkeypatch):
    """A child that never comes up must not block the caller past the
    cold-start budget — it gets a clear retryable error instead."""
    monkeypatch.setattr(bm, "_COLD_START_BUDGET", 0.2)
    mgr = _mgr()

    async def fake_serve_hangs():
        # Never sets ready, never sets session — simulates a slow/stuck
        # cold start (the real one can take up to 60s).
        stop = asyncio.Event()
        await stop.wait()

    mgr._serve = fake_serve_hangs

    started = time.monotonic()
    result = mgr._ensure_started()
    elapsed = time.monotonic() - started

    assert result == {"ok": False, "error": "browser warming up, retry"}
    assert mgr.is_warm() is False
    # Bounded by the budget, not by _READY_TIMEOUT (60s).
    assert elapsed < 2.0


def test_call_tool_returns_warming_dict_without_raising(monkeypatch):
    monkeypatch.setattr(bm, "_COLD_START_BUDGET", 0.1)
    mgr = _mgr()

    async def fake_serve_hangs():
        stop = asyncio.Event()
        await stop.wait()

    mgr._serve = fake_serve_hangs

    result = mgr.call_tool("browser_snapshot", {})
    assert result == {"ok": False, "error": "browser warming up, retry"}


def test_supervisor_restarts_dead_child_with_backoff(monkeypatch, caplog):
    """After the child dies, the supervisor restarts it in the background
    (without a caller having to call _ensure_started again) and logs the
    restart at WARNING."""
    monkeypatch.setattr(bm, "_RESTART_BACKOFF", [0.05, 0.1])
    mgr = _mgr()
    calls = {"n": 0}

    async def fake_serve():
        calls["n"] += 1
        mgr._session = object()
        mgr._became_ready = True
        mgr._ready.set()
        if calls["n"] == 1:
            await asyncio.sleep(0.05)
            raise RuntimeError("simulated child death")
        # Second (restarted) attempt: stay alive.
        stop = asyncio.Event()
        await stop.wait()

    mgr._serve = fake_serve

    caplog.set_level(logging.WARNING, logger="jc_client.browser_mcp")

    assert mgr._ensure_started() is None  # first attempt comes up warm
    assert mgr.is_warm() is True

    # It will die ~50ms later; the supervisor must bring it back on its own.
    assert _wait_until(lambda: not mgr.is_warm(), timeout=1.0)
    assert _wait_until(lambda: mgr.is_warm(), timeout=2.0)
    assert calls["n"] == 2
    assert any("restarting" in r.message for r in caplog.records)


def test_backoff_resets_after_a_healthy_attempt(monkeypatch):
    """A death after being warm shouldn't inherit a prior crash-loop's
    backoff index — it's treated as a fresh failure."""
    monkeypatch.setattr(bm, "_RESTART_BACKOFF", [0.05, 0.05, 5.0])
    mgr = _mgr()
    calls = {"n": 0}

    async def fake_serve():
        calls["n"] += 1
        if calls["n"] <= 2:
            # First two attempts die immediately without ever becoming warm
            # (crash loop) — should walk the backoff schedule.
            raise RuntimeError("boom")
        # Third attempt: becomes warm, then dies once more.
        mgr._session = object()
        mgr._became_ready = True
        mgr._ready.set()
        if calls["n"] == 3:
            await asyncio.sleep(0.02)
            raise RuntimeError("died after being healthy")
        stop = asyncio.Event()
        await stop.wait()

    mgr._serve = fake_serve
    mgr._ensure_supervisor()

    # Attempt 3 becomes warm, then dies — its death resets the backoff index,
    # so attempt 4 follows promptly (short backoff[0]) rather than waiting on
    # the long backoff[2] the earlier crash loop had walked up to.
    assert _wait_until(lambda: calls["n"] >= 3, timeout=2.0)
    assert _wait_until(lambda: mgr.is_warm(), timeout=2.0)
    assert _wait_until(lambda: calls["n"] >= 4, timeout=1.0)
    # backoff[0] was used for the post-healthy restart, so the index is now 1
    # (not 3, which is where the pre-reset crash loop would have left it).
    assert mgr._restart_backoff_idx == 1


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
