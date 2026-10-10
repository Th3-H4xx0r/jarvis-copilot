"""The car's remote commands: their names, the integration's services, and the confirmation gate."""
from __future__ import annotations

from typing import Any

from plugins.toyota.entities import EntityMap

# Our command -> the Toyota integration's Home Assistant service (domain toyota_na).
SERVICES: dict[str, str] = {
    "start": "engine_start",
    "stop": "engine_stop",
    "lock": "door_lock",
    "unlock": "door_unlock",
    "trunk_lock": "trunk_lock",
    "trunk_unlock": "trunk_unlock",
    "lights": "headlights_on",
    "horn": "sound_horn",
    "buzzer": "sound_buzzer",
    "hazards_on": "hazards_on",
    "hazards_off": "hazards_off",
}
# The entity the integration creates only when the car (and its plan) supports the command.
NEEDS: dict[str, str] = {
    "start": "btn_start", "stop": "btn_stop", "lock": "lock", "unlock": "lock",
    "trunk_lock": "btn_trunk_lock", "trunk_unlock": "btn_trunk_unlock",
    "lights": "btn_lights", "horn": "btn_horn", "buzzer": "btn_buzzer",
    "hazards_on": "btn_hazards", "hazards_off": "btn_hazards",
}
# Pranav's rule: every command but stop needs Face ID on his iPhone — a signature from the phone's
# Secure Enclave key (plugins/toyota/approver.py). Stop stays instant: turning the car off is safe.
FACE_ID: frozenset[str] = frozenset(SERVICES) - {"stop"}
DONE: dict[str, str] = {
    "start": "Started", "stop": "Stopped", "lock": "Locked", "unlock": "Unlocked",
    "trunk_lock": "Trunk locked", "trunk_unlock": "Trunk unlocked", "lights": "Headlights on",
    "horn": "Horn sounded", "buzzer": "Buzzer sounded", "hazards_on": "Hazards on",
    "hazards_off": "Hazards off",
}


def available_commands(m: EntityMap, states: dict | None = None) -> list[str]:
    """Commands the car offers. With states, one whose entity went unavailable (Remote Connect
    lapsed, say — the entity stays in the registry) is left out."""
    def usable(role: str) -> bool:
        if not m.has(role):
            return False
        if states is None:
            return True
        state = states.get(m.get(role))
        return not (isinstance(state, dict) and state.get("state") == "unavailable")
    return [name for name in SERVICES if usable(NEEDS[name])]


def is_confirmed(value: Any) -> bool:
    """Only an explicit yes counts: True, or exactly "true" from a loosely typed caller."""
    return value is True or value == "true"


def needs_face_id(command: str) -> bool:
    return command in FACE_ID
