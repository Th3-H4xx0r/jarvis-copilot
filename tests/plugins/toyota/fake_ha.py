"""A stand-in Home Assistant for the Toyota plugin's tests, plus a car like Pranav's."""
from __future__ import annotations

from plugins.toyota.entities import CORNERS, ROLES

VIN = "4T1DAACK0TU000123"
DEVICE = "dev-camry"


class FakeHA:
    """Answers like HAClient from tables; records every call."""

    url = "https://ha.test"

    def __init__(self, registry=None, states=None, handlers=("toyota_na",), entries=None, flows=None):
        self.registry = list(registry or [])
        self.state_map = dict(states or {})
        self.handlers = list(handlers)
        self.entries = list(entries or [])
        self.flows = list(flows or [])
        self.calls: list[tuple] = []
        self.replies: dict[tuple, list] = {}
        self.registry_reads = 0

    def reply(self, method, path, *answers):
        self.replies.setdefault((method, path), []).extend(answers)

    def posts(self, prefix=""):
        return [(path, body) for method, path, body in self.calls if method == "POST" and path.startswith(prefix)]

    def services(self):
        """(service, service_data) of every websocket call_service, in order."""
        return [(p["service"], p["service_data"]) for m, kind, p in self.calls if m == "WS" and kind == "call_service"]

    async def get(self, path, timeout=None):
        return self._answer("GET", path, None)

    async def post(self, path, body=None, timeout=None):
        return self._answer("POST", path, {} if body is None else body)

    async def delete(self, path):
        return self._answer("DELETE", path, None)

    async def states(self, entity_ids):
        ids = sorted({e for e in entity_ids if e})
        self.calls.append(("STATES", tuple(ids), None))
        return {e: self.state_map[e] for e in ids if e in self.state_map}

    async def entity_registry(self):
        self.registry_reads += 1
        self.calls.append(("WS", "config/entity_registry/list", None))
        return self.registry

    async def ws_call(self, kind, timeout=None, **payload):
        self.calls.append(("WS", kind, payload))
        queue = self.replies.get(("WS", kind))
        if queue:
            answer = queue.pop(0)
            if isinstance(answer, BaseException):
                raise answer
            return answer
        if kind == "call_service" and payload.get("service") == "refresh":
            self.refreshes = getattr(self, "refreshes", 0) + 1
        return {}

    async def flows_in_progress(self):
        self.calls.append(("WS", "config_entries/flow/progress", None))
        return self.flows

    def _answer(self, method, path, body):
        self.calls.append((method, path, body))
        queue = self.replies.get((method, path))
        if queue:
            answer = queue.pop(0)
            if isinstance(answer, BaseException):
                raise answer
            return answer
        if method == "GET" and path == "/api/config/config_entries/flow_handlers":
            return self.handlers
        if method == "GET" and path.startswith("/api/config/config_entries/entry"):
            return self.entries
        return {}


def entity_id(role: str) -> str:
    domain, name = ROLES[role]
    return f"{domain}.camry_{(name or 'doors').lower().replace(' ', '_')}"


def registry(roles=None, vin=VIN, **overrides) -> list[dict]:
    rows = []
    for role in roles or ROLES:
        domain, name = ROLES[role]
        row = {"entity_id": entity_id(role), "platform": "toyota_na", "unique_id": f"{vin}.{name}",
               "device_id": DEVICE, "disabled_by": None}
        row.update(overrides.get(role, {}))
        rows.append(row)
    return rows


def _state(role, value, unit=None, **attrs):
    if unit:
        attrs["unit_of_measurement"] = unit
    return entity_id(role), {"entity_id": entity_id(role), "state": value, "attributes": attrs,
                             "last_updated": "2026-10-08T20:41:00+00:00"}


def camry_states(**changes) -> dict[str, dict]:
    """His car in the screenshots: 353 mi, 63 mi on the clock, 36/36/35/36 psi, all shut and locked."""
    values = {
        "range": ("353", "mi"), "fuel": ("62", "%"), "odometer": ("63", "mi"),
        "updated": ("2026-10-08T20:41:00+00:00", None), "tires_updated": ("2026-10-08T20:41:00+00:00", None),
        "tire_fl": ("36", "psi"), "tire_fr": ("36", "psi"), "tire_rl": ("35", "psi"), "tire_rr": ("36", "psi"),
        "lock": ("locked", None), "running": ("off", None), "trunk": ("off", None), "trunk_lock": ("off", None),
        "hood": ("off", None), "next_service": ("4937", "mi"),
        "climate_custom": ("on", None), "defrost_front": ("off", None), "defrost_rear": ("off", None),
    }
    for corner in CORNERS:
        values[f"door_{corner}"] = ("off", None)
        values[f"window_{corner}"] = ("off", None)
        values[f"door_lock_{corner}"] = ("off", None)
        values[f"tire_warn_{corner}"] = ("off", None)
    values.update(changes)
    states = dict(_state(role, *v) for role, v in values.items() if v is not None)
    states.update([_state("climate_temp", "68", "°F", min=60, max=85, step=1)])
    states.update([_state("parked", "not_home", None, latitude=37.3349, longitude=-122.009)])
    for role, v in changes.items():
        if v is None:
            states.pop(entity_id(role), None)
    return states


def signed_in_ha(**kw) -> FakeHA:
    kw.setdefault("registry", registry())
    kw.setdefault("states", camry_states())
    kw.setdefault("entries", [{"entry_id": "e1", "title": "pranav@example.com", "state": "loaded"}])
    return FakeHA(**kw)
