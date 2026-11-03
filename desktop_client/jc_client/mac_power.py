"""Keep the Mac awake while it's needed, and Wake Mac (spec 2026-11-02).

* Holds (pmset disablesleep through the root helper, lid shut included) while a
  Claude/Codex session is busy or waiting on Pranav, for GRACE after the last busy
  moment, while "Keep Mac awake" is on, while a password request waits, and for
  REMOTE_IDLE after a remote wake. Released at LOW_BATTERY on battery power.
* Going to sleep arms a timer wake CHECKIN out. When that alarm wakes the Mac it
  asks the server (one HTTPS call) whether anyone wants it; if not it goes straight
  back to sleep, quietly: no hello, no reconnect, no "went to sleep" again, so the
  server never sees the check-in (no merge-back of "Continue on server").
* A Wake Mac push (via the Mac app) or a check-in that finds a request is a real
  wake, held as "remote".
"""
from __future__ import annotations

import json
import logging
import re
import socket
import subprocess
import threading
import time
from typing import Callable, Optional

log = logging.getLogger(__name__)

BUSY = frozenset({"thinking", "working", "approval", "question", "ratelimit"})
GRACE = 600.0
REMOTE_IDLE = 1800.0
CHECKIN = 900.0
LOW_BATTERY = 5
KEEP_AWAKE_MAX = 12 * 3600.0   # "Keep Mac awake" turns itself off after this
_OUR_ALARM = 120.0      # a wake this close to our alarm (and an rtc one) is the check-in
_QUIET_MAX = 60.0       # a check-in that didn't put the Mac back to sleep stops being quiet
_STATUS_EVERY = 60.0
_TICK = 10.0
HELPER_SOCKET = "/var/run/com.jarviscopilot.power.sock"


def should_hold(now: float, sessions: list, *, manual: bool, remote_since: Optional[float],
                last_busy: Optional[float], pending_password: bool, battery: tuple) -> tuple:
    """(hold?, why): why is password|session|manual|grace|remote, or "" when not holding."""
    percent, on_ac = battery
    if not on_ac and percent is not None and percent <= LOW_BATTERY:
        return False, ""
    if pending_password:
        return True, "password"
    if any((s.get("state") or "") in BUSY for s in sessions):
        return True, "session"
    if manual:
        return True, "manual"
    if last_busy is not None and now - last_busy < GRACE:
        return True, "grace"
    if remote_since is not None and now - max(remote_since, last_busy or 0) < REMOTE_IDLE:
        return True, "remote"
    return False, ""


def _run(argv: list) -> str:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=5).stdout
    except Exception:  # noqa: BLE001
        return ""


def read_battery() -> tuple:
    out = _run(["/usr/bin/pmset", "-g", "batt"])
    m = re.search(r"(\d+)%", out)
    return (int(m.group(1)) if m else None, "AC Power" in out.split("\n", 1)[0] or not m)


def read_lid() -> Optional[str]:
    m = re.search(r'"AppleClamshellState" = (Yes|No)',
                  _run(["/usr/sbin/ioreg", "-r", "-k", "AppleClamshellState", "-d", "1"]))
    return None if not m else ("closed" if m.group(1) == "Yes" else "open")


def read_wake_reason() -> str:
    m = re.search(r'"Wake Reason" = "([^"]*)"', _run(["/usr/sbin/ioreg", "-n", "IOPMrootDomain", "-r", "-d1"]))
    return m.group(1) if m else ""


def read_idle_seconds() -> float:
    """Seconds since the last key or trackpad event (IOHIDSystem's HIDIdleTime)."""
    m = re.search(r'"HIDIdleTime" = (\d+)', _run(["/usr/sbin/ioreg", "-c", "IOHIDSystem", "-d", "4"]))
    return int(m.group(1)) / 1e9 if m else 1e9


def helper_call(op: str, **kw) -> dict:
    """One request to the root helper; {"ok": False} when it isn't installed or running."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(5)
            s.connect(HELPER_SOCKET)
            s.sendall((json.dumps({"op": op, **kw}) + "\n").encode())
            line = s.makefile("r", encoding="utf-8").readline()
        return json.loads(line) if line else {"ok": False, "error": "no reply"}
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": f"power helper: {exc}"}


class MacPower:
    def __init__(self, helper: Callable[..., dict], up: Callable[[dict], None],
                 checkin: Callable[[], dict], sessions: Callable[[], list], *,
                 pending_password: Callable[[], bool] = lambda: False,
                 battery: Callable[[], tuple] = read_battery,
                 wake_reason: Callable[[], str] = read_wake_reason,
                 lid: Callable[[], Optional[str]] = read_lid,
                 idle: Callable[[], float] = None,
                 clock: Callable[[], float] = time.time,
                 mono: Callable[[], float] = time.monotonic) -> None:
        self._helper = helper
        self._up = up
        self._checkin = checkin
        self._sessions = sessions
        self._pending_password = pending_password
        self._battery = battery
        self._wake_reason = wake_reason
        self._lid = lid
        self._clock = clock
        self._mono = mono
        self._idle = idle or read_idle_seconds
        self._lock = threading.RLock()
        self._manual_since = 0.0
        self._quiet_mono: Optional[float] = None
        self._quiet_lid: Optional[str] = None
        self.manual = False
        self.timer_on = True
        self.remote_since: Optional[float] = None
        self.last_busy: Optional[float] = None
        self._held = False
        self._reason = ""
        self._wake_at: Optional[float] = None
        self._asleep = False
        self._quiet_since: Optional[float] = None
        self._last_status: Optional[dict] = None
        self._status_at = 0.0
        self._stop = threading.Event()

    # ── lifecycle ────────────────────────────────────────────────────────
    def start(self) -> None:
        def loop() -> None:
            while not self._stop.wait(_TICK):
                try:
                    self.tick()
                except Exception:  # noqa: BLE001
                    log.warning("mac power tick failed", exc_info=True)
        threading.Thread(target=loop, daemon=True, name="jc-mac-power").start()

    def close(self) -> None:
        self._stop.set()

    def _call(self, op: str, **kw) -> dict:
        try:
            return self._helper(op, **kw) or {}
        except Exception:  # noqa: BLE001
            log.debug("power helper %s failed", op, exc_info=True)
            return {}

    # ── sleep and wake ───────────────────────────────────────────────────
    def asleep(self) -> bool:
        return self._asleep

    def quiet(self) -> bool:
        """A timer check-in is in progress: don't reconnect or say hello."""
        return self._quiet_since is not None

    def on_will_sleep(self) -> bool:
        """Arm the check-in timer. False when this sleep follows a quiet check-in
        (the server already knows the Mac is asleep: don't tell it again)."""
        with self._lock:
            announce = not self.quiet()
            self._asleep = True
            self._arm()
            return announce

    def _arm(self) -> None:
        if self.timer_on:
            self._wake_at = self._clock() + CHECKIN
            self._call("wake_at", ts=self._wake_at)

    def _user_active(self) -> bool:
        """He's at the Mac (keys / trackpad since the check-in began, or opened the lid)."""
        elapsed = self._mono() - (self._quiet_mono or self._mono())
        return self._idle() < elapsed + 1.0 or (self._quiet_lid == "closed" and self._lid() == "open")

    def on_did_wake(self) -> bool:
        """True for a real wake (say hello, reconnect); False for a quiet check-in
        that found nothing and put the Mac back to sleep."""
        with self._lock:
            if not self._asleep:
                if self._quiet_since is not None:
                    # the same wake's second signal (app + clock jump): still quiet,
                    # unless he's at the Mac now
                    if not self._user_active():
                        return False
                    self._quiet_since = None
                return True
            self._asleep = False
            now = self._clock()
            ours = (self._wake_at is not None and abs(now - self._wake_at) <= _OUR_ALARM
                    and "rtc" in (self._wake_reason() or "").lower())
            if not ours:
                if self._wake_at is not None:
                    self._call("cancel_wake")
                self._wake_at = None
                self._quiet_since = None
                return True
            self._wake_at = None
            self._quiet_since = token = now
            self._quiet_mono = self._mono()
            self._quiet_lid = self._lid()
        try:
            answer = self._checkin()
        except Exception:  # noqa: BLE001 — offline: fail open, never strand him
            log.info("wake check-in failed; staying awake", exc_info=True)
            answer = None
        with self._lock:
            if self._quiet_since != token:
                return True          # a push or his own wake made it real meanwhile
            if not isinstance(answer, dict):
                self._quiet_since = None
                return True
            self._set_manual(bool(answer.get("keep_awake")), now)
            self.timer_on = answer.get("timer_on") is not False
            percent, on_ac = self._battery()
            low = not on_ac and percent is not None and percent <= LOW_BATTERY
            if not (answer.get("wake") or (self.manual and not low)) and not self._user_active():
                # nobody wants it: straight back to sleep, and arm the next check-in
                # here (a sleep from a dark wake may bring no will-sleep)
                self._asleep = True
                self._arm()
                self._call("sleepnow")
                return False
            if answer.get("wake"):
                self.remote_since = now
            self._quiet_since = None
        self.tick()
        return True

    def request_wake(self) -> None:
        """A Wake Mac push reached the app."""
        with self._lock:
            self.remote_since = self._clock()
            self._quiet_since = None
        self.tick()

    def _set_manual(self, on: bool, now: float) -> None:
        if on and not self.manual:
            self._manual_since = now
        self.manual = on

    def on_frame(self, frame: dict) -> None:
        """mac_power_set from the server: keep_awake / timer_on / let_sleep."""
        with self._lock:
            now = self._clock()
            if "keep_awake" in frame:
                self._set_manual(bool(frame.get("keep_awake")), now)
            if "timer_on" in frame:
                self.timer_on = bool(frame.get("timer_on"))
            if frame.get("let_sleep"):
                self.manual = False
                self.remote_since = None
                self.last_busy = None
        self.tick()

    # ── the hold ─────────────────────────────────────────────────────────
    def tick(self) -> None:
        with self._lock:
            now = self._clock()
            if self.manual and now - self._manual_since > KEEP_AWAKE_MAX:
                self.manual = False                    # a forgotten switch never pins it awake
                self._send({"type": "event", "name": "mac_power_set", "data": {"keep_awake": False}})
            try:
                sessions = list(self._sessions() or [])
            except Exception:  # noqa: BLE001
                sessions = []
            if any((s.get("state") or "") in BUSY for s in sessions):
                self.last_busy = now
            battery = self._battery()
            want, reason = should_hold(now, sessions, manual=self.manual, remote_since=self.remote_since,
                                       last_busy=self.last_busy, pending_password=self._pending_password(),
                                       battery=battery)
            self._reason = reason
            if want != self._held:
                # only what the helper confirms counts (not installed, restarted…)
                if self._call("hold", on=want).get("ok"):
                    self._held = want
                    if not want and not self._asleep and self._lid() == "closed":
                        self._call("sleepnow")
            elif want:
                beat = self._call("heartbeat")
                if beat.get("ok") and beat.get("held") is False:   # helper restarted: hold again
                    self._call("hold", on=True)
            if (self._quiet_since is not None and self._quiet_mono is not None
                    and self._mono() - self._quiet_mono > _QUIET_MAX):
                # awake a minute (monotonic: sleep doesn't count) after a check-in:
                # it didn't go back to sleep, so stop hiding
                self._quiet_since = None
                self._asleep = False
            if self._quiet_since is None:
                self._maybe_status(now, battery)

    def _send(self, frame: dict) -> None:
        try:
            self._up(frame)
        except Exception:  # noqa: BLE001
            log.debug("mac power up failed", exc_info=True)

    def status(self) -> dict:
        with self._lock:
            return {"state": "sleeping" if self._asleep else "awake", "held": self._held,
                    "reason": self._reason, "keep_awake": self.manual, "timer_on": self.timer_on}

    def _maybe_status(self, now: float, battery: tuple) -> None:
        data = dict(self.status(), battery=battery[0], on_ac=battery[1], lid=self._lid())
        if data == self._last_status and now - self._status_at < _STATUS_EVERY:
            return
        self._last_status = data
        self._status_at = now
        self._send({"type": "event", "name": "mac_power_status", "data": data})
