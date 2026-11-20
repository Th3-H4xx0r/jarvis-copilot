"""The PC's 15-minute wake-timer check-in (his pick 2026-11-19), the Windows twin of mac_power.MacPower's timer.

Long sleeps drop the PC off Wi-Fi (live: after ~20 h asleep its card answered no ARP, so no magic packet from the Pod
or the Mac reached it). So while awake jc-client keeps a Windows wake timer armed 15 minutes ahead; when it fires,
the PC asks the server (GET /api/coding/agents/mac/checkin) whether he wants it: yes → screen on and stay up;
no → arm the next one and sleep again, without reconnecting (the card never flickers to Awake).

Plain logic with every Windows call injected (pc_power wires the real ones), so it's tested on any OS.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Callable, Optional

log = logging.getLogger(__name__)

CHECKIN = 900.0          # how far ahead the wake timer sits (the Mac's CHECKIN)
REARM_S = 60.0           # while awake, moved forward this often: a sleep any time finds it ≤15 min away
OUR_EARLY_S = 10.0       # without the timer's own "fired" state: a resume this soon before it isn't ours…
OUR_LATE_S = 180.0       # …and up to this long after it is (resume + clock catch-up)
STALE_ASLEEP_S = 60.0    # ticking this long after a sleep mark = a resume nobody reported
UNREPORTED_S = 30.0      # the timer went off this long ago and no resume was reported: check in from the ticks
USER_ACTIVE_S = 30.0     # input this recent means someone is at the PC: a real wake
DEDUPE_S = 20.0          # the app's did_wake and the clock check can both report one resume
CHECKIN_TRIES = 8        # Wi-Fi takes a few seconds to come back after a resume
CHECKIN_RETRY_S = 5.0
REMOTE_HOLD_S = 30 * 60  # a wake he asked for stays up this long without use (his Mac rule)


class PcWake:
    def __init__(self, checkin: Callable[[], dict], *, arm: Callable[[float], None], cancel: Callable[[], None],
                 suspend: Callable[[], None], idle_seconds: Callable[[], float], display_on: Callable[[], None],
                 hold: Callable[[float], None], clock: Callable[[], float] = time.time,
                 retry_sleep: Callable[[float], None] = time.sleep,
                 fired: Optional[Callable[[], bool]] = None,
                 sleep_marker: Optional[Callable[[], float]] = None) -> None:
        self._checkin = checkin
        self._arm_fn = arm
        self._cancel = cancel
        self._suspend = suspend
        self._idle = idle_seconds
        self._display_on = display_on
        self._hold = hold
        self._clock = clock
        self._retry_sleep = retry_sleep
        # Whether the wake timer itself went off (the real answer to "was this resume ours?"; review: a
        # power-button press 90 s before the timer was taken for it and slept again).
        self._fired = fired
        # Total time slept so far (wall clock minus the awake-only clock): it changes with every sleep, so two
        # signals for one resume share it and a new resume — even 9 s later — doesn't (live 2026-11-19 23:02:
        # Wake PC 11 s after a check-in passed for that resume's duplicate; the reconnect waited a minute).
        self._sleep_marker = sleep_marker
        self._handled_marker: Optional[float] = None
        self._lock = threading.Lock()
        self.timer_on = True
        self._wake_at: Optional[float] = None
        self._armed_at: Optional[float] = None
        self._asleep = False
        self._asleep_since: Optional[float] = None
        self._quiet_since: Optional[float] = None
        self._handled_at: Optional[float] = None
        self._last_result = True
        self.seq = 0             # one per resume handled: the reconnect gate's budget restarts with it

    # ── the timer ────────────────────────────────────────────────────────
    def _arm(self) -> None:
        """Caller holds the lock."""
        if not self.timer_on:
            return
        self._wake_at = self._clock() + CHECKIN
        self._armed_at = self._clock()
        try:
            self._arm_fn(self._wake_at)
        except Exception:  # noqa: BLE001 — a wake timer that couldn't be set just means no check-in
            log.warning("pc wake timer not armed", exc_info=True)

    def tick(self) -> None:
        """While awake: keep the timer ~15 minutes ahead (and heal a resume nobody reported)."""
        with self._lock:
            now = self._clock()
            if self._fired is not None and self._safe_fired():
                # It went off and that resume isn't classified yet: keep its signal — unless nobody reported the
                # resume at all, then classify it from here.
                unreported = self._wake_at is None or now - self._wake_at > UNREPORTED_S
                if not unreported:
                    return
            else:
                unreported = False
                if self._asleep and self._asleep_since is not None and now - self._asleep_since > STALE_ASLEEP_S:
                    self._asleep, self._quiet_since = False, None   # we're ticking, so we're awake
                if not self.timer_on or self._quiet_since is not None:
                    return
                if self._armed_at is None or now - self._armed_at >= REARM_S:
                    self._arm()
        if unreported:
            log.info("pc wake: the timer went off and no resume was reported; checking in from the ticks")
            self.on_did_wake()

    def _marker(self) -> Optional[float]:
        if self._sleep_marker is None:
            return None
        try:
            return float(self._sleep_marker())
        except Exception:  # noqa: BLE001
            return None

    def _safe_fired(self) -> bool:
        try:
            return bool(self._fired())
        except Exception:  # noqa: BLE001
            return False

    def _mark_asleep(self) -> None:
        self._asleep, self._asleep_since = True, self._clock()

    def set_timer(self, on: bool) -> None:
        with self._lock:
            self.timer_on = bool(on)
            if not on:
                self._wake_at = self._armed_at = None
                try:
                    self._cancel()
                except Exception:  # noqa: BLE001
                    log.debug("pc wake timer cancel failed", exc_info=True)
            else:
                self._arm()

    # ── sleep and wake ───────────────────────────────────────────────────
    def quiet(self) -> bool:
        """A timer check-in is in progress (or ended in a re-sleep): don't reconnect or say hello."""
        return self._quiet_since is not None

    def asleep(self) -> bool:
        return self._asleep

    def on_will_sleep(self) -> bool:
        """Arm the timer. False when this sleep follows a quiet check-in (the server already knows)."""
        with self._lock:
            if self._fired is not None and self._safe_fired():
                # Late: the app's will_sleep for a sleep that already ended (our timer woke it). Re-arming here
                # would wipe the timer's fired state and the resume would pass for his (live 2026-11-19 01:12).
                log.info("pc wake: late will_sleep after the timer went off; ignored")
                return False
            announce = self._quiet_since is None
            self._quiet_since = None
            self._mark_asleep()
            self._arm()
            return announce

    def on_did_wake(self) -> bool:
        """True for a real wake (his hands, a magic packet, a wake he asked for); False when it was our timer
        and nobody wants the PC — it's going straight back to sleep."""
        with self._lock:
            now = self._clock()
            if self._quiet_since is not None and not self._asleep:
                return False                 # a check-in for this resume is already running (review: a 2nd one lost his wake)
            marker = self._marker()
            if marker is not None and self._handled_marker is not None:
                if abs(marker - self._handled_marker) < 2.0:
                    return self._last_result         # the same resume, reported twice
            elif self._handled_at is not None and now - self._handled_at < DEDUPE_S:
                return self._last_result
            self._handled_at, self._handled_marker = now, marker
            self._asleep = False
            self.seq += 1
            timer_went_off = (self._safe_fired() if self._fired is not None else
                              self._wake_at is not None and -OUR_EARLY_S <= now - self._wake_at <= OUR_LATE_S)
            idle = self._idle()
            ours = timer_went_off and idle >= USER_ACTIVE_S
            if not ours:
                log.info("pc wake: a real wake (timer went off: %s, idle %.0f s)", timer_went_off, idle)
                self._quiet_since = None
                self._last_result = True
                self._arm()                  # consume any fired signal; the next sleep finds a fresh timer
                return True
            self._quiet_since = token = now
        answer = self._ask()
        with self._lock:
            if self._quiet_since != token:      # his hands woke it meanwhile
                self._last_result = True
                self._arm()
                return True
            if isinstance(answer, dict):
                self.timer_on = answer.get("timer_on") is not False
            if isinstance(answer, dict) and answer.get("wake"):
                log.info("pc wake: timer check-in — he asked for the PC: screen on, staying up")
                self._quiet_since = None
                self._last_result = True
                self._arm()
                wanted = True
            elif self._idle() < USER_ACTIVE_S:   # he sat down during the check-in
                self._quiet_since = None
                self._last_result = True
                self._arm()
                return True
            else:
                log.info("pc wake: timer check-in — nobody asked (%s); sleeping again",
                         "no answer" if answer is None else "wake false")
                self._mark_asleep()
                self._arm()
                self._last_result = False
                wanted = False
        if wanted:
            self._display_on()
            self._hold(REMOTE_HOLD_S)
            return True
        self._suspend()
        return False

    def _ask(self) -> Optional[dict]:
        for attempt in range(CHECKIN_TRIES):
            try:
                answer = self._checkin()
                return answer if isinstance(answer, dict) else None
            except Exception:  # noqa: BLE001 — Wi-Fi still coming back
                if attempt < CHECKIN_TRIES - 1:
                    self._retry_sleep(CHECKIN_RETRY_S)
        log.info("pc wake check-in got no answer; sleeping again to retry at the next timer")
        return None
