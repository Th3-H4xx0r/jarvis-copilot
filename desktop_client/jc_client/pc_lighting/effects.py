"""The lighting maths. The PC renders every frame with it and the iPhone runs the same formulas
(Copilot/PC/PcEffects.swift) on the 3D model, so the model glows LED by LED with what the fans show.
golden.json pins both: change a formula here and in Swift together, then regenerate the fixture.
"""
from __future__ import annotations

import colorsys
import math

EFFECTS = ("static", "breathing", "rainbow", "spectrum", "comet")
PARTS = ("top", "rear", "bottom", "cooler", "strip")

RGB = tuple[int, int, int]


def parse_hex(color: str) -> tuple[float, float, float]:
    c = (color or "").lstrip("#")
    if len(c) != 6:
        raise ValueError(f"colour must be #rrggbb, got {color!r}")
    return tuple(int(c[k:k + 2], 16) / 255.0 for k in (0, 2, 4))  # type: ignore[return-value]


def _frac(x: float) -> float:
    return x % 1.0


def _unit(effect: str, color: str, speed: int, seg_ord: int, i: int, n: int, t: float) -> tuple[float, float, float]:
    if effect == "static":
        return parse_hex(color)
    if effect == "breathing":
        k = 0.15 + 0.85 * (0.5 - 0.5 * math.cos(2 * math.pi * t * speed / 10))
        return tuple(v * k for v in parse_hex(color))  # type: ignore[return-value]
    if effect == "rainbow":
        return colorsys.hsv_to_rgb(_frac(i / n + seg_ord * 0.12 + t * speed / 20), 1.0, 1.0)
    if effect == "spectrum":
        return colorsys.hsv_to_rgb(_frac(t * speed / 40), 1.0, 1.0)
    if effect == "comet":
        head = _frac(t * speed / 8 + seg_ord * 0.25) * n
        value = max(0.0, 1.0 - ((head - i) % n) / (0.35 * n))
        return tuple(v * value for v in parse_hex(color))  # type: ignore[return-value]
    raise ValueError(f"unknown effect {effect!r}")


def colour(effect: str, color: str, speed: int, seg_ord: int, i: int, n: int, t: float) -> RGB:
    """LED `i` of `n` in the segment that is `seg_ord`-th in the map, `t` seconds into the effect."""
    r, g, b = _unit(effect, color, speed, seg_ord, i, max(1, n), t)
    return (round(r * 255), round(g * 255), round(b * 255))


def frame(state: dict, ledmap: dict, now: float) -> dict[tuple[int, int], list[RGB]]:
    """Every mapped zone's full colour list for this instant; LEDs no segment covers stay black."""
    out: dict[tuple[int, int], list[RGB]] = {
        (z["controller"], z["zone"]): [(0, 0, 0)] * int(z["leds"]) for z in ledmap.get("zones", [])}
    if not state.get("on", True):
        return out
    scale = max(0, min(100, int(state.get("brightness", 100)))) / 100.0
    t0 = float(state.get("t0") or 0.0)
    t = (float(state["frozen_at"]) if state.get("frozen_at") is not None else now) - t0
    parts = state.get("parts") or {}
    for seg_ord, seg in enumerate(ledmap.get("segments", [])):
        p = parts.get(seg["part"])
        leds = out.get((seg["controller"], seg["zone"]))
        if not p or leds is None:
            continue
        n = int(seg["count"])
        for i in range(n):
            pos = int(seg["start"]) + i
            if 0 <= pos < len(leds):
                r, g, b = colour(p["effect"], p["color"], int(p.get("speed", 5)), seg_ord, i, n, t)
                leds[pos] = (round(r * scale), round(g * scale), round(b * scale))
    return out
