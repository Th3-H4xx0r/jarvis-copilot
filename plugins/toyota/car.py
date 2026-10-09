"""Pranav's car through Home Assistant: the snapshot, remote commands, the remote-start climate."""
from __future__ import annotations

import asyncio
import time
from typing import Any, Callable

from plugins.toyota.commands import CONFIRM, DONE, SERVICES, available_commands, is_confirmed
from plugins.toyota.entities import DOMAIN, EntityMap, build_map
from plugins.toyota.ha import COMMAND_TIMEOUT, HAClient, HAError, HATimeout
from plugins.toyota.snapshot import as_float, build_snapshot

SIGN_IN_FIRST = "Sign in with Toyota on the Car page first."
MAP_TTL = 300.0
# After a wake: how long to wait for the car's new report, and how often to look.
REFRESH_WAIT = 12.0
REFRESH_POLL = 2.0
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


class CommandPending(HAError):
    """Toyota hasn't answered in time; the car may still carry the command out."""

    def __init__(self) -> None:
        super().__init__("No answer from the car yet. It may still do it: check the car before trying again.", 504)


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

    async def entity_map(self, fresh: bool = False) -> EntityMap:
        """The car's entities, cached for reads. Anything that acts on the car asks for a fresh
        map: if the integration was re-added in HA, the old device id would be ignored quietly
        and the command reported as done."""
        key = self.ha.url
        cached = dict(_cache)   # one read: a sign-out on another thread may clear it meanwhile
        if (not fresh and cached["key"] == key and cached["map"] is not None
                and self.clock() - cached["at"] < MAP_TTL):
            return cached["map"]
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
        m = await self.entity_map(fresh=True)
        if name not in available_commands(m):
            raise CarError(f"Your car doesn't offer '{name}' right now (it needs Toyota Remote Connect).")
        await self._vehicle_service(m, SERVICES[name])
        return {"ok": True, "command": name, "result": DONE[name]}

    async def refresh(self, wait: float = REFRESH_WAIT) -> dict[str, Any]:
        """Wake the car for fresh status, then wait (up to `wait` s) for its new report — the
        integration reads it some seconds after the wake."""
        m = await self.entity_map(fresh=True)
        updated = m.get("updated")
        before = await self._reading(updated)
        await self._vehicle_service(m, "refresh")
        deadline = self.clock() + wait
        while updated and self.clock() < deadline:
            await asyncio.sleep(REFRESH_POLL)
            if await self._reading(updated) != before:
                return {"ok": True, "fresh": True}
        return {"ok": True, "fresh": False}

    async def _reading(self, entity_id: str | None) -> Any:
        if not entity_id:
            return None
        return ((await self.ha.states([entity_id])).get(entity_id) or {}).get("state")

    async def set_climate(self, *, custom: Any = None, temp: Any = None,
                          defrost_front: Any = None, defrost_rear: Any = None) -> dict[str, Any]:
        """Change the saved remote-start climate. Every value is checked before any is changed."""
        m = await self.entity_map(fresh=True)
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
        try:
            await self.ha.ws_call("call_service", timeout=COMMAND_TIMEOUT, domain=DOMAIN, service=service,
                                  service_data={"vehicle": m.device_id})
        except HATimeout as exc:
            raise CommandPending() from exc
