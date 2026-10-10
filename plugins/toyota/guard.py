"""Keeps the general Home Assistant tool (ha_call_service) from working the car around Face ID.

Every car command but stop goes through toyota_command, which needs Pranav's Face ID on his
iPhone. Registered into tools.homeassistant_tool.SERVICE_GUARDS by this plugin's register().
"""
from __future__ import annotations

from typing import Any

from plugins.toyota.entities import DOMAIN

USE_THE_TOOL = "Use toyota_command for the car: its commands need Pranav's Face ID on his iPhone."
_GUARDED = {("lock", "lock"), ("lock", "unlock"), ("lock", "open"), ("button", "press")}
# Everything toyota_command gates behind Face ID — all of it but Remote Stop and Refresh Status.
_PROTECTED_ROLES = ("lock", "btn_start", "btn_trunk_lock", "btn_trunk_unlock", "btn_lights", "btn_horn",
                    "btn_buzzer", "btn_hazards")
_WIDE_TARGETS = ("device_id", "area_id", "floor_id", "label_id")


def _targets(entity_id: Any, data: dict) -> list[str] | None:
    """The entity ids a call aims at, or None when it aims wider (devices, areas, everything)."""
    ids: list[str] = []

    def add(value: Any) -> None:
        if isinstance(value, str):
            # Home Assistant lower-cases entity ids before it acts, so compare them that way.
            ids.extend(part.strip().lower() for part in value.split(",") if part.strip())
        elif isinstance(value, (list, tuple)):
            for item in value:
                add(item)

    add(entity_id)
    add(data.get("entity_id"))
    target = data.get("target")
    if isinstance(target, dict):
        add(target.get("entity_id"))
        if any(target.get(k) for k in _WIDE_TARGETS):
            return None
    if any(data.get(k) for k in _WIDE_TARGETS) or not ids or "all" in ids:
        return None
    return ids


def _protected_ids() -> set[str] | None:
    """The car's lock / Remote Start / Unlock Cargo Door entities; None if that can't be checked."""
    from plugins.toyota import service
    from plugins.toyota.car import NotSignedIn, ToyotaCar
    from plugins.toyota.ha import HAClient, HAError

    try:
        m = service.run(ToyotaCar(HAClient()).entity_map())
    except NotSignedIn:
        return set()
    except HAError:
        return None
    return {m.get(role) for role in _PROTECTED_ROLES if m.get(role)}


def _scene_targets(data: dict) -> list[str]:
    """The entities a scene.apply / scene.create would set (it calls their services itself)."""
    found: list[str] = []
    entities = data.get("entities")
    if isinstance(entities, dict):
        found.extend(str(k).strip().lower() for k in entities)
    elif isinstance(entities, (list, tuple)):
        found.extend(str(k).strip().lower() for k in entities)
    snapshot = data.get("snapshot_entities")
    if isinstance(snapshot, (list, tuple)):
        found.extend(str(k).strip().lower() for k in snapshot)
    elif isinstance(snapshot, str):
        found.extend(part.strip().lower() for part in snapshot.split(","))
    return found


def guard(domain: str, service: str, entity_id: Any, data: Any) -> str | None:
    """A refusal for ha_call_service, or None to let the call through."""
    if domain == DOMAIN:
        return f"The Toyota integration's services can't be called directly. {USE_THE_TOOL}"
    if domain == "scene" and service in ("apply", "create"):
        targets = _scene_targets(data if isinstance(data, dict) else {})
        if not targets:
            return None
        protected = _protected_ids()
        if protected is None:
            return "Couldn't check whether that scene touches the car, so it wasn't applied."
        return USE_THE_TOOL if protected & set(targets) else None
    if (domain, service) not in _GUARDED:
        return None
    targets = _targets(entity_id, data if isinstance(data, dict) else {})
    if targets is None:
        return f"Call {domain}.{service} on named entities only, so the car can't be caught in it. {USE_THE_TOOL}"
    protected = _protected_ids()
    if protected is None:
        return f"Couldn't check whether that's the car, so {domain}.{service} wasn't sent."
    if protected & set(targets):
        return USE_THE_TOOL
    return None
