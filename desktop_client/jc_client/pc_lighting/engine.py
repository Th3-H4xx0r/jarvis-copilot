"""The lighting engine on the PC: turns the lighting state + LED map into frames and writes them to OpenRGB.

Static colours are written once (and again only on a change); animated effects at most 30 times a second.
While a game runs and the state says still_in_games, the frame freezes (frozen_at) until the game ends.
Calibration probes pause it. The last state and map are kept on disk so the lights come back at login
before the server reconnects. Every change is reported up as a pc_lighting_state event.
"""
from __future__ import annotations

import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Any, Callable, Optional

from jc_client.pc_lighting import effects

log = logging.getLogger(__name__)

FRAME_S = 1 / 30
_CH = {"r": 0, "g": 1, "b": 2}


def _led_power(v: int) -> int:
    """One sRGB channel (0–255) to the LED drive that gives the same light."""
    c = v / 255
    lin = c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return round(lin * 255)


_LED = [_led_power(v) for v in range(256)]
RETRY_S = 10.0
PROBE_S = 60.0
REPORT_S = 60.0
WHITE = "#ffffff"


def _default_store() -> Path:
    try:
        from jc_client import credentials
        return Path(credentials._CONFIG_FILE).parent / "pc_lighting.json"
    except Exception:  # noqa: BLE001
        return Path.home() / ".jarviscopilot-client" / "pc_lighting.json"


def _default_game_state():
    from jc_client import game_mode
    return game_mode.current()


def _default_driver(address: str):
    from jc_client.pc_lighting.driver import Driver
    return Driver(address)


class Engine:
    def __init__(self, send_up: Callable[[dict], Any], driver_factory: Callable[[str], Any] = _default_driver,
                 clock: Callable[[], float] = time.time, game_state: Callable[[], Any] = _default_game_state,
                 store_path: Optional[Path] = None) -> None:
        self._send_up = send_up
        self._factory = driver_factory
        self._clock = clock
        self._game = game_state
        self._store = store_path or _default_store()
        self._lock = threading.RLock()
        self._driver = None
        self._controllers: list[dict] = []
        self._enabled = True
        self._state: Optional[dict] = None
        self._rev: Optional[int] = None
        self._map: dict = {}
        self._address = "127.0.0.1:6742"
        self._dirty = True
        self._last_write = float("-inf")
        self._error: Optional[str] = None
        self._next_retry = 0.0
        self._paused = False
        self._frozen_at: Optional[float] = None
        self._probing = False
        self._probe_at = 0.0
        self._sizes_dirty = True
        self._direct = False
        self._unsent = False          # a report that didn't go (the link to the server was down)
        self._gen = 0                 # bumps on every state/map change (a write outside the lock checks it)
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._load()

    # ── commands from the server (skills) ────────────────────────────────────
    def set_state(self, state: dict, rev: Optional[int] = None, address: Optional[str] = None,
                  enabled: bool = True) -> dict:
        with self._lock:
            if rev is not None and self._rev is not None and rev < self._rev:
                return self.status()          # an older change arriving late never undoes a newer one
            self._gen += 1
            self._state = dict(state)
            self._rev = rev
            if address and address != self._address:
                self._address = address
                self._driver = None
                self._next_retry = 0.0
            self._enabled = bool(enabled)
            self._probing = False
            self._dirty = True
            self._save()
        self._emit()
        return self.status()

    def set_map(self, ledmap: dict) -> dict:
        with self._lock:
            self._map = dict(ledmap or {})
            self._gen += 1
            self._probing = False
            self._sizes_dirty = True
            self._dirty = True
            self._save()
        self._emit()
        return self.status()

    def set_enabled(self, enabled: bool) -> None:
        with self._lock:
            self._enabled = bool(enabled)
            self._dirty = True
            self._save()
        self._emit()

    def probe(self, args: dict) -> dict:
        """Calibration: light one LED (or a range) in one zone, every other zone dark; pauses the engine."""
        with self._lock:
            if args.get("clear"):
                self._probing = False
                self._dirty = True
                return {"ok": True}
            driver = self._ensure_driver(self._clock())
            if driver is None:
                return {"ok": False, "error": self._error or "OpenRGB isn't connected"}
            c, z = int(args["controller"]), int(args["zone"])
            if args.get("resize"):
                driver.resize(c, z, int(args["resize"]))
                self._set_zone_leds(c, z, int(args["resize"]))
            frame = {key: [(0, 0, 0)] * n for key, n in self._zone_sizes().items()}
            leds = frame.setdefault((c, z), [])
            rgb = tuple(round(v * 255) for v in effects.parse_hex(args.get("color") or WHITE))
            if args.get("led") is not None:
                lit = [int(args["led"])]
            elif args.get("range"):
                start, count = (int(v) for v in args["range"])
                lit = list(range(start, start + count))
            else:
                lit = []
            for k in lit:
                if 0 <= k < len(leds):
                    leds[k] = rgb   # type: ignore[assignment]
            try:
                self._write(driver, frame)
            except Exception as exc:  # noqa: BLE001
                self._fail(exc, self._clock())
                return {"ok": False, "error": self._error}
            self._probing = True
            self._probe_at = self._clock()
            return {"ok": True}

    def reconnect(self) -> dict:
        """Drop the connection and try OpenRGB again now (setup just started it)."""
        with self._lock:
            self._driver = None
            self._next_retry = 0.0
            self._ensure_driver(self._clock())
        return self.status()

    def status(self) -> dict:
        with self._lock:
            engine = "stopped" if not self._enabled else ("error" if self._error else "running")
            return {"state_rev": self._rev, "map_version": self._map.get("rev"), "engine": engine,
                    "error": self._error, "paused_for_game": self._paused, "controllers": list(self._controllers)}

    def measure(self, seconds: float = 10.0) -> float:
        """Average % of one core this process uses while rendering a rainbow on every LED of every zone
        OpenRGB reports (setup's cost check). Holds the lock so the tick thread can't write meanwhile."""
        rainbow = {"on": True, "brightness": 100, "t0": time.time(), "frozen_at": None,
                   "parts": {p: {"effect": "rainbow", "color": WHITE, "speed": 5} for p in effects.PARTS}}
        with self._lock:
            driver = self._ensure_driver(self._clock())
            sizes = self._zone_sizes()
            ledmap = {"zones": [{"controller": c, "zone": z, "leds": n} for (c, z), n in sizes.items()],
                      "segments": [{"part": "strip", "index": 0, "controller": c, "zone": z, "start": 0, "count": n}
                                   for (c, z), n in sizes.items()]}
            cpu0, wall0 = time.process_time(), time.monotonic()
            while time.monotonic() - wall0 < seconds:
                frames = effects.frame(rainbow, ledmap, time.time())
                if driver is not None:
                    try:
                        self._write(driver, frames)
                    except Exception:  # noqa: BLE001
                        driver = None
                time.sleep(FRAME_S)
            wall = max(1e-6, time.monotonic() - wall0)
            self._dirty = True
        return float((time.process_time() - cpu0) / wall * 100.0)

    # ── the loop ─────────────────────────────────────────────────────────────
    def tick(self) -> None:
        emit = False
        if self._unsent:
            self._emit()
        with self._lock:
            now = self._clock()
            if self._probing and now - self._probe_at > PROBE_S:
                self._probing = False        # calibration was left mid-way: render again
                self._dirty = True
            if not self._enabled or self._probing:
                return
            # Connect even before there's a map: calibration needs the controllers and their zones.
            driver = self._ensure_driver(now)
            if driver is None or not self._state or not self._map.get("segments"):
                return
            if self._sizes_dirty:
                self._fit_zones(driver)
            st = self._state
            animated = st.get("on", True) and any(
                (p or {}).get("effect", "static") != "static" for p in (st.get("parts") or {}).values())
            game = self._game()
            pause = bool(getattr(game, "on", False)) and bool(st.get("still_in_games")) and animated
            if pause != self._paused:
                self._paused = pause
                self._frozen_at = now if pause else None
                self._dirty = True
                emit = True
            if not self._dirty and (not animated or self._paused or now - self._last_write < FRAME_S - 1e-9):
                return
            render = dict(st, frozen_at=self._frozen_at) if self._paused else st
            frames = self._ordered(effects.frame(render, self._map, now))
            gen = self._gen
            self._last_write = now
        # The write happens outside the lock: his board's USB link is slow per full-board frame, and a
        # colour change from the server must never wait behind it (those waits were the 15 s 502s).
        try:
            self._write(driver, frames)
            with self._lock:
                if gen == self._gen:
                    self._dirty = False
        except Exception as exc:  # noqa: BLE001
            with self._lock:
                self._fail(exc, now)
            emit = True
        if emit:
            self._emit()

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop.clear()

        def loop():
            last_report = 0.0
            while not self._stop.wait(FRAME_S):
                try:
                    self.tick()
                    if time.monotonic() - last_report > REPORT_S:
                        last_report = time.monotonic()
                        self._emit()
                except Exception:  # noqa: BLE001 — never kill the loop
                    log.exception("lighting tick failed")

        self._thread = threading.Thread(target=loop, name="pc-lighting", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None

    # ── helpers ──────────────────────────────────────────────────────────────
    def _ensure_driver(self, now: float):
        if self._driver is not None:
            return self._driver
        if now < self._next_retry:
            return None
        try:
            d = self._factory(self._address)
            d.connect()
            self._controllers = d.controllers()
            self._driver = d
            self._direct = False          # Direct mode only right before the first write: connecting leaves the lights alone
            self._error = None
            self._dirty = True
            self._sizes_dirty = True
            self._emit()                  # the server (and calibration) learn the controllers now
            return d
        except Exception as exc:  # noqa: BLE001
            self._fail(exc, now)
            self._emit()
            return None

    def _ordered(self, frames: dict) -> dict:
        """Screen colours as LED power (sRGB decoded: an LED's light is linear in its drive, so a raw
        33 % blue tints red pink), then each connector's colour order (its LEDs may be GRB)."""
        orders = {(z["controller"], z["zone"]): str(z.get("order") or "rgb") for z in self._map.get("zones", [])}
        out = {}
        for key, colours in frames.items():
            colours = [(_LED[r], _LED[g], _LED[b]) for r, g, b in colours]
            order = orders.get(key, "rgb")
            if order != "rgb" and sorted(order) == ["b", "g", "r"]:
                a, b, c = (_CH[ch] for ch in order)
                out[key] = [(col[a], col[b], col[c]) for col in colours]
            else:
                out[key] = colours
        return out

    def _write(self, driver, frames: dict) -> None:
        if not self._direct:
            driver.set_direct()
            self._direct = True
        driver.write(frames)

    def _fit_zones(self, driver) -> None:
        """Resizable zones take the calibrated LED count (calibration measured them at 300)."""
        self._sizes_dirty = False
        resizable = {(c["index"], z["index"]): z for c in self._controllers for z in c.get("zones", [])
                     if z.get("resizable")}
        for z in self._map.get("zones", []):
            key, want = (z["controller"], z["zone"]), int(z["leds"])
            info = resizable.get(key)
            if info is not None and int(info.get("leds", 0)) != want:
                try:
                    driver.resize(key[0], key[1], want)
                    info["leds"] = want
                except Exception:  # noqa: BLE001
                    log.warning("couldn't resize zone %s to %s", key, want, exc_info=True)

    def _fail(self, exc: Exception, now: float) -> None:
        self._driver = None
        self._error = f"Can't drive the lights through OpenRGB at {self._address}: {exc}"
        self._next_retry = now + RETRY_S
        log.warning("%s", self._error)

    def _zone_sizes(self) -> dict[tuple[int, int], int]:
        sizes = {(c["index"], z["index"]): int(z["leds"]) for c in self._controllers for z in c.get("zones", [])}
        for z in self._map.get("zones", []):
            sizes.setdefault((z["controller"], z["zone"]), int(z["leds"]))
        return sizes

    def _set_zone_leds(self, c: int, z: int, n: int) -> None:
        for ctl in self._controllers:
            if ctl["index"] == c:
                for zone in ctl.get("zones", []):
                    if zone["index"] == z:
                        zone["leds"] = n

    def _emit(self) -> None:
        try:
            went = self._send_up({"type": "event", "name": "pc_lighting_state", "data": self.status()})
        except Exception:  # noqa: BLE001
            went = False
        self._unsent = went is False   # send_up_ok says False while offline; try again next tick

    def _save(self) -> None:
        try:
            self._store.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._store.with_suffix(".tmp")
            tmp.write_text(json.dumps({"state": self._state, "rev": self._rev, "map": self._map,
                                       "address": self._address, "enabled": self._enabled}), encoding="utf-8")
            os.replace(tmp, self._store)
        except Exception:  # noqa: BLE001
            log.debug("couldn't save lighting state", exc_info=True)

    def _load(self) -> None:
        try:
            data = json.loads(self._store.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            return
        self._state = data.get("state")
        self._rev = data.get("rev")
        self._map = data.get("map") or {}
        self._address = data.get("address") or self._address
        self._enabled = bool(data.get("enabled", True))
