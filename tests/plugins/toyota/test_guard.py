"""The general Home Assistant tool can't unlock or start the car behind toyota_command."""
import json

import pytest

import plugins.toyota.guard as guard_module
from plugins.toyota.guard import guard


@pytest.fixture(autouse=True)
def car_entities(monkeypatch):
    monkeypatch.setattr(guard_module, "_protected_ids",
                        lambda: {"lock.camry_doors", "button.camry_remote_start", "button.camry_unlock_cargo_door",
                                 "button.camry_sound_horn", "button.camry_flash_hazards"})


@pytest.mark.parametrize("domain,service,entity_id,data", [
    ("toyota_na", "door_unlock", None, {"vehicle": "dev"}),
    ("toyota_na", "engine_start", None, {}),
    ("lock", "unlock", "lock.camry_doors", None),
    ("lock", "open", None, {"entity_id": ["lock.front_door", "lock.camry_doors"]}),
    ("button", "press", None, {"target": {"entity_id": "button.camry_remote_start"}}),
    ("lock", "unlock", None, {"device_id": "dev"}),
    ("lock", "unlock", None, {}),
    ("lock", "unlock", "all", None),
    ("lock", "lock", "lock.camry_doors", None),
    ("button", "press", "button.camry_sound_horn", None),
    ("button", "press", None, {"entity_id": "button.camry_flash_hazards"}),
    ("lock", "unlock", None, {"entity_id": "Lock.Camry_Doors"}),
    ("button", "press", "BUTTON.camry_remote_start", None),
    ("lock", "unlock", None, {"entity_id": "ALL"}),
    ("scene", "apply", None, {"entities": {"lock.camry_doors": "unlocked"}}),
    ("scene", "create", None, {"scene_id": "x", "snapshot_entities": ["lock.camry_doors"]}),
])
def test_ways_round_the_confirmation_are_refused(domain, service, entity_id, data):
    assert guard(domain, service, entity_id, data)


@pytest.mark.parametrize("domain,service,entity_id,data", [
    ("lock", "unlock", "lock.front_door", None),
    ("lock", "lock", "lock.front_door", None),
    ("button", "press", "button.doorbell_chime", None),
    ("light", "turn_on", None, {"area_id": "kitchen"}),
    ("scene", "apply", None, {"entities": {"light.kitchen": "on"}}),
])
def test_everything_else_goes_through(domain, service, entity_id, data):
    assert guard(domain, service, entity_id, data) is None


def test_the_plugin_puts_its_guard_on_ha_call_service(monkeypatch):
    import tools.homeassistant_tool as ha_tool
    from plugins.toyota import register

    class Ctx:
        def register_tool(self, **kw):
            pass

    monkeypatch.setattr(ha_tool, "SERVICE_GUARDS", [])
    register(Ctx())
    register(Ctx())
    assert ha_tool.SERVICE_GUARDS == [guard]
    out = json.loads(ha_tool._handle_call_service({"domain": "lock", "service": "unlock", "entity_id": "lock.camry_doors"}))
    assert "toyota_command" in out["error"]
