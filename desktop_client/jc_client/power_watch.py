"""Sleep and wake on the Mac.

The Jarvis Mac app hears the system's will-sleep / did-wake notifications and
passes them on over ui.sock (``notify``). Without the app, wake still shows up
as a jump between the wall clock and the monotonic clock (which stops while
the Mac sleeps), checked every few seconds.
"""
from __future__ import annotations

import threading
import time
from typing import Callable


class PowerWatch:
    def __init__(self, on_sleep: Callable[[], None], on_wake: Callable[[], None], *,
                 clock=time.time, mono=time.monotonic, jump: float = 30.0,
                 every: float = 10.0) -> None:
        self._on_sleep = on_sleep
        self._on_wake = on_wake
        self._clock = clock
        self._mono = mono
        self._jump = jump
        self._every = every
        self._base = self._clock() - self._mono()
        self._stop = threading.Event()
        self._thread = None

    def notify(self, event: str) -> None:
        if event == "will_sleep":
            self._on_sleep()
        elif event == "did_wake":
            self._base = self._clock() - self._mono()
            self._on_wake()

    def check_jump(self) -> None:
        base = self._clock() - self._mono()
        if base - self._base > self._jump:
            self._base = base
            self._on_wake()
        else:
            self._base = base

    def start(self) -> None:
        if self._thread is not None:
            return

        def loop():
            while not self._stop.wait(self._every):
                try:
                    self.check_jump()
                except Exception:  # noqa: BLE001
                    pass

        self._thread = threading.Thread(target=loop, daemon=True, name="jc-power-watch")
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
