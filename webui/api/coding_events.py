"""Process-wide pub/sub for INSTANT coding-session WebUI updates (SSE).

The coding panel used to learn about state changes only by polling
(``/api/coding/sessions`` every 5s, ``/session/<id>`` every 4s). This is the
push side that replaces that lag: any state change — a hook-driven
``/activity-event``, the server poll backstop detecting a change, or a
lifecycle mutation (launch/stop/delete) — calls :func:`notify`, which fans a
tiny "something changed, refetch now" nudge out to every connected browser so
it updates the instant the change happens. The polls remain as a fallback for
when the SSE connection drops.

A single global fan-out (not per-session): the panel shows ALL sessions, so one
stream per browser suffices. Mirrors the clarify/approval SSE registries
(``api.clarify``), but simpler — the payload carries no per-session routing.
"""
from __future__ import annotations

import queue
import threading

_lock = threading.Lock()
_subscribers: list[queue.Queue] = []


def subscribe() -> queue.Queue:
    """Register a bounded Queue for SSE push; call :func:`unsubscribe` to drop."""
    q: queue.Queue = queue.Queue(maxsize=16)
    with _lock:
        _subscribers.append(q)
    return q


def unsubscribe(q: queue.Queue) -> None:
    """Remove a subscriber Queue (idempotent)."""
    with _lock:
        try:
            _subscribers.remove(q)
        except ValueError:
            pass


def subscriber_count() -> int:
    with _lock:
        return len(_subscribers)


def notify(payload: dict | None = None) -> None:
    """Fan a change-nudge out to all subscribers. Never raises.

    Drops the nudge for any slow subscriber whose bounded queue is full — a
    missed nudge is harmless (the next one, or the poll fallback, catches up)
    and the bound prevents an unbounded memory leak.
    """
    payload = payload or {"type": "coding-changed"}
    with _lock:
        subs = list(_subscribers)
    for q in subs:
        try:
            q.put_nowait(payload)
        except queue.Full:
            pass
