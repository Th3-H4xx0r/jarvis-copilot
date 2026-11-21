"""Lighting skills the server calls over the bridge. Server-only (device_bridge.SERVER_ONLY_SKILLS):
Jarvis drives the lights through the server's pc_lighting tools, which apply the LED map and the Power switch."""
from __future__ import annotations

from typing import Any, Optional

_engine: Any = None


def set_engine(engine: Any) -> None:
    global _engine
    _engine = engine


def _missing() -> dict:
    return {"ok": False, "error": "PC lighting isn't running in jc-client"}


def lighting_state_set(state: dict, rev: Optional[int] = None, address: Optional[str] = None,
                       enabled: bool = True) -> dict:
    return _engine.set_state(state, rev=rev, address=address, enabled=enabled) if _engine else _missing()


def lighting_map_set(map: dict) -> dict:  # noqa: A002 — the contract's name
    return _engine.set_map(map) if _engine else _missing()


def lighting_probe(controller: Optional[int] = None, zone: Optional[int] = None, resize: Optional[int] = None,
                   led: Optional[int] = None, range: Optional[list] = None,  # noqa: A002
                   color: Optional[str] = None, clear: bool = False) -> dict:
    if not _engine:
        return _missing()
    args = {"controller": controller, "zone": zone, "resize": resize, "led": led, "range": range,
            "color": color, "clear": clear or None}
    return _engine.probe({k: v for k, v in args.items() if v is not None})


def lighting_status() -> dict:
    return dict(_engine.status(), ok=True) if _engine else _missing()


def lighting_setup(step: str, sensor_driver: bool = True) -> dict:
    if not _engine:
        return _missing()
    from jc_client.pc_lighting import setup
    return setup.run_step(step, sensor_driver, engine=_engine)


def register() -> None:
    from jc_client.skills import skill
    obj = {"type": "object"}
    skill("lighting_state_set", "Server-only: set the PC lighting state (per-part effect/colour, brightness, on).",
          {"type": "object", "properties": {"state": obj, "rev": {"type": "integer"}, "address": {"type": "string"},
                                            "enabled": {"type": "boolean"}}, "required": ["state"]})(lighting_state_set)
    skill("lighting_map_set", "Server-only: set which OpenRGB LEDs belong to which part of the PC.",
          {"type": "object", "properties": {"map": obj}, "required": ["map"]})(lighting_map_set)
    skill("lighting_probe", "Server-only: calibration — light one LED or a range in one zone (or clear).",
          {"type": "object", "properties": {"controller": {"type": "integer"}, "zone": {"type": "integer"},
                                            "resize": {"type": "integer"}, "led": {"type": "integer"},
                                            "range": {"type": "array"}, "color": {"type": "string"},
                                            "clear": {"type": "boolean"}}})(lighting_probe)
    skill("lighting_status", "Server-only: the PC lighting engine's status and OpenRGB controllers.",
          {"type": "object"})(lighting_status)
    skill("lighting_setup", "Server-only: run one PC lighting setup step (may wait for Face ID).",
          {"type": "object", "properties": {"step": {"type": "string"}, "sensor_driver": {"type": "boolean"}},
           "required": ["step"]}, destructive=True, watchdog=lambda a: 960.0)(lighting_setup)
