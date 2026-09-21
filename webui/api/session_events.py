"""Per-session event fan-out: how a device learns what another device just did.

A run already broadcasts correctly. ``STREAMS[stream_id]`` holds a
``StreamChannel`` whose ``subscribe()`` gives every subscriber its own queue, so
two clients watching one ``stream_id`` each receive every event. What is missing
is everything AROUND that:

* ``stream_id`` is ``uuid4().hex`` per run and is handed only to the client that
  started it, so nobody else can attach even though attaching would work;
* title changes, renames, creates and deletes ride no stream at all.

This bus carries those announcements, keyed by ``session_id`` -- which, unlike
``stream_id``, every device already knows. It deliberately carries pointers and
not content: a ``run_started`` says "attach to this stream_id", and the existing
run stream plus its journal deliver the actual tokens.

Unlike ``StreamChannel`` this deliberately has NO offline buffer. A session
channel outlives every run on that session, so anything buffered there goes stale
and never stops growing: a ``run_started`` held while nobody was watching, then
replayed hours later, points at a stream that has long since ended -- the server
finds no live channel, falls back to the on-disk journal, and replays a FINISHED
turn from seq 0, so opening an old chat spontaneously re-runs its last answer.

It is also unnecessary. A subscriber attaches BEFORE its snapshot is taken, and
that snapshot reports the live run with a liveness check the buffer never had.
Nobody listening therefore means nobody to tell, and whoever arrives next is
brought up to date by the snapshot instead.

Subscriber queues are bounded and drop for a consumer that has stopped reading,
matching ``gateway_watcher``'s pool rather than the chat one -- but a drop also
pushes a ``resync``, because a client that silently misses one announcement
misses a whole turn while still looking perfectly connected.
"""

from __future__ import annotations

import logging
import queue
import threading
import time
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

Event = Tuple[str, Dict[str, Any]]

# A client this far behind is not reading. Nudges are replaceable; memory is not.
DEFAULT_QUEUE_SIZE = 256


class _Channel:
    """One session's subscribers plus the tail for whoever has not arrived yet."""

    def __init__(self, queue_size: int) -> None:
        self._lock = threading.Lock()
        self._subscribers: List[queue.Queue] = []
        self._queue_size = queue_size
        self._dropped = 0

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=self._queue_size)
        with self._lock:
            self._subscribers.append(q)
        return q

    def unsubscribe(self, q: queue.Queue) -> int:
        with self._lock:
            try:
                self._subscribers.remove(q)
            except ValueError:
                pass
            return len(self._subscribers)

    def publish(self, item: Event) -> None:
        # The puts stay INSIDE the lock: the queues are bounded and put_nowait
        # never blocks, so holding it costs nothing, and releasing it first lets
        # two publishers interleave -- a subscriber could then see run_ended
        # before the run_started it belongs to.
        with self._lock:
            subscribers = list(self._subscribers)
            for q in subscribers:
                try:
                    q.put_nowait(item)
                except queue.Full:
                    # This client stopped reading. Dropping silently would mean it
                    # misses a whole turn while still looking perfectly connected,
                    # so make room and tell it to re-read the session.
                    self._dropped += 1
                    try:
                        q.get_nowait()
                        q.put_nowait(("resync", {}))
                    except (queue.Empty, queue.Full):
                        pass
                    logger.warning(
                        "session events: subscriber queue full, dropped %s (total=%d)",
                        item[0], self._dropped,
                    )

    def is_idle(self) -> bool:
        with self._lock:
            return not self._subscribers

    def count(self) -> int:
        with self._lock:
            return len(self._subscribers)


class SessionEventBus:
    """``session_id`` -> :class:`_Channel`, created on demand and reaped when idle."""

    def __init__(self, queue_size: int = DEFAULT_QUEUE_SIZE) -> None:
        self._lock = threading.Lock()
        self._channels: Dict[str, _Channel] = {}
        self._queue_size = queue_size

    def _channel(self, session_id: str) -> _Channel:
        with self._lock:
            ch = self._channels.get(session_id)
            if ch is None:
                ch = _Channel(self._queue_size)
                self._channels[session_id] = ch
            return ch

    def _existing(self, session_id: str) -> Optional[_Channel]:
        with self._lock:
            return self._channels.get(session_id)

    def subscribe(self, session_id: str) -> queue.Queue:
        # Atomic under the bus lock. Two steps -- look up, then attach -- lets a
        # concurrent unsubscribe reap the channel in between, so the queue is
        # attached to a detached object and every later publish goes to a freshly
        # created channel instead. The SSE connection stays healthy and keepalives
        # keep flowing, so the device just silently stops mirroring. Reloading a
        # page or switching sessions on two devices is exactly that interleaving.
        # Ordering stays bus -> channel, so this introduces no inversion.
        with self._lock:
            ch = self._channels.get(session_id)
            if ch is None:
                ch = _Channel(self._queue_size)
                self._channels[session_id] = ch
            return ch.subscribe()

    def unsubscribe(self, session_id: str, q: queue.Queue) -> None:
        ch = self._existing(session_id)
        if ch is None:
            return
        if ch.unsubscribe(q):
            return
        # Last one out: drop the channel so the bus does not accumulate one entry
        # per session id ever opened. Re-check idleness under the bus lock so a
        # subscriber that arrived in between is not silently orphaned.
        with self._lock:
            current = self._channels.get(session_id)
            if current is ch and current.is_idle():
                self._channels.pop(session_id, None)

    def publish(self, session_id: str, event: str,
                data: Optional[Dict[str, Any]] = None) -> None:
        if not session_id:
            return
        # Never CREATE a channel to publish into. Session.save() announces on every
        # save, so creating here would leave one channel per session id ever
        # touched, forever, with nobody on the other end.
        ch = self._existing(session_id)
        if ch is None:
            return
        ch.publish((event, dict(data or {})))

    def subscriber_count(self, session_id: str) -> int:
        ch = self._existing(session_id)
        return ch.count() if ch is not None else 0

    def channel_count(self) -> int:
        with self._lock:
            return len(self._channels)


# The process-wide bus. One per WebUI process, like STREAMS.
SESSION_EVENTS = SessionEventBus()
