"""Background poll that detects the live ``activity_state`` of SERVER-HOST
coding sessions from their tmux pane and writes it to the store.

Server-host only: desktop-host sessions are classified Mac-side and reported via
the discovery push (``desktop_client/jc_client/coding_discover.py`` →
``webui/api/coding_desktop.ingest_discovered``). The loop clock/sleep are
injectable for tests; per-row errors are swallowed so one bad session can't kill
the tick. Mirrors ``agent/coding_scheduler_loop.py`` and the ``gateway_watcher``
daemon-thread pattern.

Activation (last-mile, in ``webui/server.py main()`` after ``start_watcher()``)::

    from agent.coding_status_loop import start_status_loop
    from tools.coding_session_tool import _mgr
    _status_thread, _status_stop = start_status_loop(_mgr())
    # ... and in finally: _status_stop.set()
"""
from __future__ import annotations

import threading
import time

from agent.coding_activity_state import classify_pane

# Lifecycle statuses for which a live activity_state is meaningful. A stopped /
# errored session has no live pane to classify.
_LIVE_STATUSES = {"running", "starting", "idle"}


def run_status_tick(manager, *, classify=classify_pane) -> int:
    """Classify each live server-host session's pane and persist
    ``activity_state`` when it changed. Returns the count updated.

    Skips desktop-host sessions (classified Mac-side) and any non-live session.
    Every per-row failure (tmux gone, capture error) is swallowed.
    """
    try:
        rows = manager.store.list_sessions()
    except Exception:
        return 0
    driver = manager.driver
    updated = 0
    for row in rows:
        try:
            if row.get("host") != "server":
                continue
            if row.get("status") not in _LIVE_STATUSES:
                continue
            tmux_name = row.get("tmux_name")
            if not tmux_name:
                continue
            state = classify(driver.capture_pane(tmux_name=tmux_name))
            if state != row.get("activity_state"):
                manager.store.update_session(row["id"], activity_state=state)
                updated += 1
        except Exception:
            continue
    return updated


def run_loop(manager, *, stop, interval: float = 4.0,
             sleep_fn=time.sleep, classify=classify_pane) -> None:
    """Tick until ``stop()`` is truthy. ``sleep_fn`` injectable for tests."""
    while not stop():
        try:
            run_status_tick(manager, classify=classify)
        except Exception:
            pass
        sleep_fn(interval)


def start_status_loop(manager, *, interval: float = 4.0):
    """Start the poll on a daemon thread. Returns ``(thread, stop_event)``;
    call ``stop_event.set()`` to stop it."""
    stop_event = threading.Event()
    t = threading.Thread(
        target=run_loop, args=(manager,),
        kwargs={"stop": stop_event.is_set, "interval": interval},
        daemon=True, name="coding-status")
    t.start()
    return t, stop_event
