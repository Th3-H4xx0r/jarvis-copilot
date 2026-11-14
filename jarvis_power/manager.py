"""Starting and stopping Power integrations' background work in this process.

The webui and the gateway each run one manager. At boot it starts the integrations
that are on and declare this process; a daemon thread then watches the shared state
(``state.version()``) every few seconds and starts/stops whatever changed, so a
switch flipped from any device or process takes effect everywhere within seconds.
"""
from __future__ import annotations

import logging
import threading
from typing import Callable, Optional

from jarvis_power import discovery, state

logger = logging.getLogger(__name__)

POLL_SECONDS = 3.0
_managers: dict[str, "PowerManager"] = {}
_current: Optional["PowerManager"] = None


class PowerManager:
    def __init__(self, process: str, loop=None, on_change: Optional[Callable[[str], None]] = None):
        self.process = process
        self.loop = loop                      # the gateway's asyncio loop, for adapters
        self.on_change = on_change
        self._running: set[str] = set()
        self._failed: set[str] = set()          # start() raised: stop() still owed on switch-off
        self._lock = threading.RLock()
        self._seen: Optional[str] = None
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def is_running(self, integration_id: str) -> bool:
        return integration_id in self._running

    def reconcile(self) -> None:
        """Start what's on and stopped; stop what's off and running. Safe to call any time."""
        with self._lock:
            states = state.snapshot_fresh()
            for p in discovery.integrations().values():
                if self.process not in p.processes:
                    continue
                want = states.get(p.id, True)
                have = p.id in self._running or (not want and p.id in self._failed)
                if want == have:
                    continue
                verb = "start" if want else "stop"
                try:
                    (p.start if want else p.stop)(self.process)
                except Exception as exc:
                    logger.exception("power: %s %s failed in %s", verb, p.id, self.process)
                    state.record_error(p.id, f"Couldn't {verb}: {exc}")
                    if want:
                        self._failed.add(p.id)
                    else:                              # a failed stop still counts as off
                        self._running.discard(p.id)
                        self._failed.discard(p.id)
                    continue
                self._failed.discard(p.id)
                if want:
                    self._running.add(p.id)
                else:
                    self._running.discard(p.id)
                if state.doc(p.id).get("error"):
                    state.record_error(p.id, None)

    def tick(self) -> None:
        """One poll: reconcile and announce when the shared state changed."""
        current = state.version()
        if current == self._seen:
            return
        self.reconcile()
        current = state.version()             # reconcile may have recorded an error
        self._seen = current
        if self.on_change is not None:
            try:
                self.on_change(current)
            except Exception:
                logger.exception("power: change announcement failed")

    def start(self) -> None:
        """Boot: reconcile now, then keep watching on a daemon thread."""
        global _current
        _current = self
        self.tick()
        if self._thread is None:
            self._thread = threading.Thread(target=self._run, name=f"power-{self.process}",
                                            daemon=True)
            self._thread.start()

    def _run(self) -> None:
        while not self._stop.wait(POLL_SECONDS):
            try:
                self.tick()
            except Exception:
                logger.exception("power: manager tick failed")

    def stop(self) -> None:
        self._stop.set()


def manager_for(process: str, loop=None, on_change=None) -> PowerManager:
    m = _managers.get(process)
    if m is None:
        m = _managers[process] = PowerManager(process, loop=loop, on_change=on_change)
    else:
        if loop is not None:
            m.loop = loop
        if on_change is not None:
            m.on_change = on_change
    return m


def current() -> Optional[PowerManager]:
    """The manager running in this process, if one was started."""
    return _current
