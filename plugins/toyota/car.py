"""Pranav's car through Home Assistant: the snapshot, remote commands, the remote-start climate."""
from __future__ import annotations

import time
from typing import Any, Callable

from plugins.toyota.commands import CONFIRM, DONE, SERVICES, available_commands, is_confirmed
from plugins.toyota.entities import DOMAIN, EntityMap, build_map
from plugins.toyota.ha import COMMAND_TIMEOUT, HAClient
from plugins.toyota.snapshot import as_float, build_snapshot

SIGN_IN_FIRST = "Sign in with Toyota on the Car page first."
MAP_TTL = 300.0
_cache: dict[str, Any] = {"key": None, "at": 0.0, "map": None}

# (argument, role, how it reads in an error)
_CLIMATE_SWITCHES = (
    ("custom", "climate_custom", "custom climate"),
    ("defrost_front", "defrost_front", "front defrost"),
    ("defrost_rear", "defrost_rear", "rear defrost"),
)
_CLIMATE_ROLES = ("climate_temp", "climate_custom", "defrost_front", "defrost_rear")


class NotSignedIn(Exception):
    """Toyota isn't usable: signed out, signed out by Toyota, or Home Assistant can't be reached."""


class CarError(Exception):
    """A request the car can't take: unknown command, not on its plan, a bad value."""


def clear_map_cache() -> None:
    _cache.update(key=None, at=0.0, map=None)


def _flag(name: str, value: Any) -> bool:
    if isinstance(value, bool):
        return value
    word = str(value).strip().lower()
    if word in ("on", "true"):
        return True
    if word in ("off", "false"):
        return False
    raise CarError(f"{name} takes true or false.")


class ToyotaCar:
    def __init__(self, ha: HAClient, clock: Callable[[], float] = time.monotonic) -> None:
        self.ha = ha
        self.clock = clock

    async def entity_map(self) -> EntityMap:
        key = self.ha.url
        if _cache["key"] == key and _cache["map"] is not None and self.clock() - _cache["at"] < MAP_TTL:
            return _cache["map"]
        found = build_map(await self.ha.entity_registry())
        if found is None:
            clear_map_cache()
            raise NotSignedIn(SIGN_IN_FIRST)
        _cache.update(key=key, at=self.clock(), map=found)
        return found

    async def snapshot(self) -> dict[str, Any]:
        m = await self.entity_map()
        ids = list(m.by_role.values()) + [entity_id for entity_id, _ in m.health_extra]
        return build_snapshot(m, await self.ha.states(ids))

    async def command(self, name: str, confirmed: Any = False) -> dict[str, Any]:
        if name not in SERVICES:
            raise CarError(f"Unknown car command '{name}'. Use one of: {', '.join(SERVICES)}.")
        # The gate comes before anything touches Home Assistant.
        if name in CONFIRM and not is_confirmed(confirmed):
            return {"ok": False, "needs_confirmation": True, "command": name, "ask": CONFIRM[name]}
        m = await self.entity_map()
        if name not in available_commands(m):
            raise CarError(f"Your car doesn't offer '{name}' right now (it needs Toyota Remote Connect).")
        await self._vehicle_service(m, SERVICES[name])
        return {"ok": True, "command": name, "result": DONE[name]}

    async def refresh(self) -> dict[str, Any]:
        """Ask the car for fresh status (wakes it)."""
        await self._vehicle_service(await self.entity_map(), "refresh")
        return {"ok": True}

    async def set_climate(self, *, custom: Any = None, temp: Any = None,
                          defrost_front: Any = None, defrost_rear: Any = None) -> dict[str, Any]:
        """Change the saved remote-start climate. Every value is checked before any is changed."""
        m = await self.entity_map()
        given = {"custom": custom, "defrost_front": defrost_front, "defrost_rear": defrost_rear}
        switches = []
        for arg, role, label in _CLIMATE_SWITCHES:
            if given[arg] is None:
                continue
            entity_id = m.get(role)
            if not entity_id:
                raise CarError(f"Your car doesn't offer {label}.")
            switches.append((entity_id, _flag(arg, given[arg])))
        number = None
        if temp is not None:
            entity_id = m.get("climate_temp")
            if not entity_id:
                raise CarError("Your car doesn't offer a climate temperature.")
            attrs = ((await self.ha.states([entity_id])).get(entity_id) or {}).get("attributes") or {}
            low, high = as_float(attrs.get("min"), 60.0), as_float(attrs.get("max"), 85.0)
            value = as_float(temp)
            if value is None or not low <= value <= high:
                raise CarError(f"Pick a temperature from {low:g} to {high:g}.")
            number = (entity_id, value)
        if number is None and not switches:
            raise CarError("Nothing to change: give custom, temp, defrost_front or defrost_rear.")
        if number is not None:
            await self.ha.post("/api/services/number/set_value", {"entity_id": number[0], "value": number[1]})
        for entity_id, on in switches:
            await self.ha.post(f"/api/services/switch/turn_{'on' if on else 'off'}", {"entity_id": entity_id})
        fresh = await self.ha.states([m.get(r) for r in _CLIMATE_ROLES if m.get(r)])
        return {"ok": True, "climate": build_snapshot(m, fresh)["climate"]}

    async def _vehicle_service(self, m: EntityMap, service: str) -> None:
        if not m.device_id:
            raise CarError("Home Assistant has no device for your car.")
        await self.ha.post(f"/api/services/{DOMAIN}/{service}", {"vehicle": m.device_id},
                           timeout=COMMAND_TIMEOUT)
