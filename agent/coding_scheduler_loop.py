"""Background tick that delivers due scheduled messages into coding sessions.

Bridges :class:`agent.coding_scheduler.CodingScheduler` to
:class:`agent.coding_session_manager.CodingSessionManager`: on each tick, due
schedules are fired by sending their message into the target session. The loop
clock + sleep are injectable so it is unit-testable without real time.

Activation (last-mile, in the running webui/gateway process)::

    from agent.coding_scheduler import CodingScheduler
    from agent.coding_scheduler_loop import run_loop
    import threading
    sched = CodingScheduler()
    stop = threading.Event()
    threading.Thread(target=run_loop, args=(sched, manager),
                     kwargs={"stop": stop.is_set}, daemon=True).start()
"""
from __future__ import annotations

import time


def make_send(manager):
    """A ``send(session_id, message)`` that relays into a coding session,
    swallowing per-delivery errors so one bad session can't kill the loop."""
    def _send(session_id, message):
        try:
            manager.send_message(session_id, message)
        except Exception:
            pass
    return _send


def tick(scheduler, manager, now: float) -> int:
    """Fire every schedule due at ``now`` into its session. Returns count fired."""
    return scheduler.run_due(now, make_send(manager))


def run_loop(scheduler, manager, *, stop, interval: float = 15.0,
             now_fn=time.time, sleep_fn=time.sleep) -> None:
    """Tick until ``stop()`` is truthy. ``now_fn``/``sleep_fn`` injectable for tests."""
    while not stop():
        try:
            tick(scheduler, manager, now_fn())
        except Exception:
            pass
        sleep_fn(interval)
