"""Which Home Assistant entities belong to Pranav's car.

The Toyota (North America) integration (orienw/ha-toyota-na, audited and pinned at v2.10.1) gives
every entity the unique id ``"<VIN>.<name>"``; the main door lock's name is ``""``. Matching on
(entity domain, name) instead of entity ids keeps working if he renames an entity in Home Assistant.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass

DOMAIN = "toyota_na"

# role -> (entity domain, name after "<VIN>.")
ROLES: dict[str, tuple[str, str]] = {
    # Command entities: the integration only creates them when the car and its plan support them.
    "btn_start": ("button", "Remote Start"),
    "btn_stop": ("button", "Remote Stop"),
    "btn_hazards": ("button", "Flash Hazards"),
    "btn_horn": ("button", "Sound Horn"),
    "btn_lights": ("button", "Turn On Headlights"),
    "btn_buzzer": ("button", "Sound Buzzer"),
    "btn_trunk_lock": ("button", "Lock Cargo Door"),
    "btn_trunk_unlock": ("button", "Unlock Cargo Door"),
    "lock": ("lock", ""),
    # Readings
    "running": ("binary_sensor", "Remote Start"),
    "range": ("sensor", "Distance To Empty"),
    "gas_range": ("sensor", "Gasoline Range"),
    "fuel": ("sensor", "Fuel Level"),
    "odometer": ("sensor", "Odometer"),
    "updated": ("sensor", "Last Update Timestamp"),
    "tires_updated": ("sensor", "Last Tire Pressure Update Timestamp"),
    "next_service": ("sensor", "Next Service"),
    "tire_warn_spare": ("binary_sensor", "Spare Tire Pressure Warning"),
    # The climate the car uses when remote-started
    "climate_temp": ("number", "Climate Temperature"),
    "climate_custom": ("switch", "Use Climate Settings"),
    "defrost_front": ("switch", "Front Defroster"),
    "defrost_rear": ("switch", "Rear Defroster"),
    # Where it is
    "parked": ("device_tracker", "Last Parked Location"),
    "located": ("device_tracker", "Current Location"),
    # Openings
    "trunk": ("binary_sensor", "Trunk"),
    "trunk_lock": ("binary_sensor", "Trunk Door Lock"),
    "hood": ("binary_sensor", "Hood"),
    "moonroof": ("binary_sensor", "Moonroof"),
}

# His car is left-hand drive: the driver's side is the left.
CORNERS: dict[str, str] = {"fl": "Front Driver", "fr": "Front Passenger",
                           "rl": "Rear Driver", "rr": "Rear Passenger"}
ROLES.update({role: key for corner, side in CORNERS.items() for role, key in (
    (f"tire_{corner}", ("sensor", f"{side} Tire")),
    (f"tire_warn_{corner}", ("binary_sensor", f"{side} Tire Pressure Warning")),
    (f"door_{corner}", ("binary_sensor", f"{side} Door")),
    (f"door_lock_{corner}", ("binary_sensor", f"{side} Door Lock")),
    (f"window_{corner}", ("binary_sensor", f"{side} Window")),
)})

# Health readings some cars report (the integration's README: oil status, key-fob battery).
HEALTH_WORDS = ("oil", "key fob")


@dataclass(frozen=True)
class EntityMap:
    vin: str
    device_id: str | None
    by_role: dict[str, str]
    health_extra: tuple[tuple[str, str], ...] = ()

    def get(self, role: str) -> str | None:
        return self.by_role.get(role)

    def has(self, role: str) -> bool:
        return role in self.by_role


def build_map(registry: list[dict]) -> EntityMap | None:
    """The car's entities from the registry rows, or None when the integration has no car."""
    rows = []
    for row in registry:
        if row.get("platform") != DOMAIN or row.get("disabled_by"):
            continue
        unique_id, entity_id = str(row.get("unique_id") or ""), str(row.get("entity_id") or "")
        if "." not in unique_id or "." not in entity_id:
            continue
        vin, name = unique_id.split(".", 1)
        rows.append((vin, name, entity_id, row.get("device_id")))
    if not rows:
        return None
    # One car on his account; if there were more, the one with the most entities.
    vin = Counter(r[0] for r in rows).most_common(1)[0][0]
    lookup: dict[tuple[str, str], str] = {}
    devices: Counter = Counter()
    extra = []
    for row_vin, name, entity_id, device_id in rows:
        if row_vin != vin:
            continue
        domain = entity_id.split(".", 1)[0]
        lookup.setdefault((domain, name), entity_id)
        if device_id:
            devices[device_id] += 1
        if domain in ("sensor", "binary_sensor") and any(w in name.lower() for w in HEALTH_WORDS):
            extra.append((entity_id, name))
    by_role = {role: lookup[key] for role, key in ROLES.items() if key in lookup}
    device_id = devices.most_common(1)[0][0] if devices else None
    return EntityMap(vin, device_id, by_role, tuple(sorted(extra)))
