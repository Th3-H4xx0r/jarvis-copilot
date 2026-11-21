"""OpenRGB over its SDK (openrgb-python, PC only). Thin on purpose: the engine decides what to write."""
from __future__ import annotations

import time
from typing import Callable
from urllib.parse import urlparse

DEFAULT_HOST, DEFAULT_PORT = "127.0.0.1", 6742


def parse_address(address: str) -> tuple[str, int]:
    """'host[:port]' or a URL → (host, port); empty → OpenRGB on this PC."""
    a = (address or "").strip()
    if not a:
        return DEFAULT_HOST, DEFAULT_PORT
    if "://" in a:
        u = urlparse(a)
        return u.hostname or DEFAULT_HOST, u.port or DEFAULT_PORT
    host, _, port = a.rstrip("/").partition(":")
    return host or DEFAULT_HOST, int(port) if port.isdigit() else DEFAULT_PORT


class Driver:
    def __init__(self, address: str, sleep: Callable[[float], None] = time.sleep) -> None:
        self.host, self.port = parse_address(address)
        self._client = None
        self._sleep = sleep
        self._last: dict = {}          # (controller, zone) → the colours last sent

    def connect(self) -> None:
        from openrgb import OpenRGBClient  # PC only (pyproject: sys_platform == 'win32')
        self._client = OpenRGBClient(self.host, self.port, name="Jarvis")

    def _devices(self):
        if self._client is None:
            raise ConnectionError("not connected to OpenRGB")
        return self._client.devices

    def controllers(self) -> list[dict]:
        out = []
        for i, dev in enumerate(self._devices()):
            # openrgb-python 0.3.8: the size limits live on the device's ZoneData, the location on metadata.
            limits = list(getattr(getattr(dev, "data", None), "zones", None) or [])
            zones = []
            for k, z in enumerate(dev.zones):
                zd = limits[k] if k < len(limits) else None
                lo, hi = getattr(zd, "leds_min", None), getattr(zd, "leds_max", None)
                zones.append({"index": k, "name": z.name, "leds": len(z.leds),
                              "resizable": lo is not None and hi is not None and lo != hi, "max": hi})
            location = getattr(getattr(dev, "metadata", None), "location", "") or ""
            out.append({"index": i, "name": dev.name, "location": location, "zones": zones})
        return out

    def set_direct(self) -> None:
        """Direct mode, only where a controller isn't in it already: on his ASRock re-setting Direct blanks
        every light and swallows the next update (confirmed live), and a real switch needs a moment."""
        switched = False
        for dev in self._devices():
            modes = list(getattr(dev, "modes", None) or [])
            active = getattr(dev, "active_mode", None)
            current = modes[active].name if modes and isinstance(active, int) and 0 <= active < len(modes) else ""
            if current.lower() in ("direct", "custom"):
                continue
            for name in ("Direct", "direct", "Custom", "custom"):
                try:
                    dev.set_mode(name)
                    switched = True
                    break
                except Exception:  # noqa: BLE001 — not every controller has every mode name
                    continue
        if switched:
            self._sleep(0.6)

    def write(self, frames: dict) -> None:
        try:
            from openrgb.utils import RGBColor
        except ImportError:  # tests off the PC
            def RGBColor(r, g, b):  # noqa: N802
                return (r, g, b)
        # One whole-device update per controller: his ASRock B760M-C (Polychrome USB) ignores per-zone
        # updates (UPDATEZONELEDS) and only shows UPDATELEDS — what OpenRGB's own app sends. Zones a frame
        # leaves out keep the colours they were last sent.
        devices = self._devices()
        by_device: dict = {}
        for (c, z), colours in frames.items():
            by_device.setdefault(c, {})[z] = colours
        for c, zones in by_device.items():
            dev = devices[c]
            out = []
            for k, zone in enumerate(dev.zones):
                n = len(zone.leds)   # fitted to the live zone: set_colors raises on a count mismatch
                fitted = (list(zones.get(k, self._last.get((c, k), []))) + [(0, 0, 0)] * n)[:n]
                self._last[(c, k)] = fitted
                out += fitted
            dev.set_colors([RGBColor(*rgb) for rgb in out], fast=True)

    def resize(self, controller: int, zone: int, leds: int) -> None:
        self._devices()[controller].zones[zone].resize(leds)
        self._client.update()
