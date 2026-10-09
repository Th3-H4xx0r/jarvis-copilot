"""The car as one JSON-ready snapshot: what the Car page draws and toyota_status returns."""
from __future__ import annotations

import math
from typing import Any, Callable, Optional

from plugins.toyota.commands import available_commands
from plugins.toyota.entities import CORNERS, EntityMap

MI_PER_KM = 0.621371
TO_PSI = {"psi": 1.0, "kpa": 0.145038, "bar": 14.5038}
_NO_VALUE = {"unknown", "unavailable", "", None}

State = Optional[dict]
Get = Callable[[str], State]


def as_float(raw: Any, default: float | None = None) -> float | None:
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return default
    return value if math.isfinite(value) else default


def _attrs(state: State) -> dict:
    return (state or {}).get("attributes") or {}


def _num(state: State) -> float | None:
    return None if state is None else as_float(state.get("state"))


def _unit(state: State) -> str:
    return str(_attrs(state).get("unit_of_measurement") or "").strip()


def _on(state: State) -> bool | None:
    return None if state is None else state.get("state") == "on"


def _miles(state: State) -> int | None:
    value = _num(state)
    if value is None:
        return None
    return round(value * MI_PER_KM if _unit(state).lower() == "km" else value)


def _psi(state: State) -> float | None:
    value = _num(state)
    if value is None:
        return None
    return round(value * TO_PSI.get(_unit(state).lower(), 1.0), 1)


def _reading(state: dict) -> str:
    return f"{state.get('state')} {_unit(state)}".strip()


def build_snapshot(m: EntityMap, states: dict[str, dict]) -> dict[str, Any]:
    def get(role: str) -> State:
        entity_id = m.get(role)
        state = states.get(entity_id) if entity_id else None
        if not isinstance(state, dict) or state.get("state") in _NO_VALUE:
            return None
        return state

    tires = _tires(get)
    return {
        "vin_last4": m.vin[-4:],
        "range_mi": _miles(get("range") or get("gas_range")),
        "fuel_pct": _num(get("fuel")),
        "odometer_mi": _miles(get("odometer")),
        "updated_at": (get("updated") or {}).get("state"),
        "running": bool(_on(get("running"))),
        "commands": available_commands(m, states),
        "climate": _climate(get),
        "tires": tires,
        "doors": _doors(m, get),
        "windows": _windows(m, get),
        "trunk": _part(get, "trunk", "Trunk", lock_role="trunk_lock"),
        "hood": _part(get, "hood", "Hood"),
        "moonroof": _part(get, "moonroof", "Moonroof"),
        "health": _health(m, states, get, tires),
        "location": _location(get),
    }


def _climate(get: Get) -> dict | None:
    temp, custom = get("climate_temp"), get("climate_custom")
    front, rear = get("defrost_front"), get("defrost_rear")
    if temp is None and custom is None and front is None and rear is None:
        return None
    attrs = _attrs(temp)
    return {
        "custom": _on(custom), "temp": _num(temp), "unit": _unit(temp) or "°F",
        "min": as_float(attrs.get("min"), 60.0), "max": as_float(attrs.get("max"), 85.0),
        "step": as_float(attrs.get("step"), 1.0),
        "defrost_front": _on(front), "defrost_rear": _on(rear),
    }


def _tires(get: Get) -> dict | None:
    values = {corner: _psi(get(f"tire_{corner}")) for corner in CORNERS}
    if all(v is None for v in values.values()):
        return None
    warnings = [side for corner, side in CORNERS.items() if _on(get(f"tire_warn_{corner}"))]
    if _on(get("tire_warn_spare")):
        warnings.append("Spare")
    return {**values, "unit": "psi", "updated_at": (get("tires_updated") or {}).get("state"),
            "warnings": warnings}


def _doors(m: EntityMap, get: Get) -> dict | None:
    corners = [c for c in CORNERS if m.has(f"door_{c}") or m.has(f"door_lock_{c}")]
    if not corners and not m.has("lock"):
        return None
    lock = get("lock")
    if lock is not None:
        locked: bool | None = lock.get("state") == "locked"
    else:
        # A door's lock sensor reads "on" while that door is unlocked.
        flags = [f for f in (_on(get(f"door_lock_{c}")) for c in corners) if f is not None]
        locked = (not any(flags)) if flags else None
    return {"open": [CORNERS[c] for c in corners if _on(get(f"door_{c}"))], "locked": locked}


def _windows(m: EntityMap, get: Get) -> dict | None:
    corners = [c for c in CORNERS if m.has(f"window_{c}")]
    if not corners:
        return None
    return {"open": [CORNERS[c] for c in corners if _on(get(f"window_{c}"))], "locked": None}


def _part(get: Get, role: str, title: str, lock_role: str | None = None) -> dict | None:
    state = get(role)
    lock = get(lock_role) if lock_role else None
    if state is None and lock is None:
        return None
    return {"open": [title] if _on(state) else [], "locked": None if lock is None else not _on(lock)}


def _health(m: EntityMap, states: dict[str, dict], get: Get, tires: dict | None) -> list[dict]:
    items = []
    if tires is not None:
        bad = tires["warnings"]
        items.append({"id": "tires", "title": "Tire pressure", "ok": not bad,
                      "detail": "Good" if not bad else "Check " + ", ".join(w.lower() for w in bad)})
    service = get("next_service")
    if service is not None:
        items.append({"id": "next_service", "title": "Next service", "ok": True, "detail": _reading(service)})
    for entity_id, name in m.health_extra:
        state = states.get(entity_id)
        if not isinstance(state, dict) or state.get("state") in _NO_VALUE:
            continue
        if entity_id.startswith("binary_sensor."):
            ok = state.get("state") != "on"
            items.append({"id": entity_id, "title": name, "ok": ok, "detail": "OK" if ok else "Needs attention"})
        else:
            items.append({"id": entity_id, "title": name, "ok": True, "detail": _reading(state)})
    return items


def _location(get: Get) -> dict | None:
    # Toyota's own Find shows where the car was last parked; real-time location is the fallback.
    for role in ("parked", "located"):
        state = get(role)
        attrs = _attrs(state)
        lat, lon = as_float(attrs.get("latitude")), as_float(attrs.get("longitude"))
        if state is not None and lat is not None and lon is not None:
            return {"lat": lat, "lon": lon, "at": state.get("last_updated"), "source": role}
    return None
