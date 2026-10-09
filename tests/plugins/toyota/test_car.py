"""Remote commands (with Pranav's confirmation rule) and the remote-start climate."""
import asyncio

import pytest

from plugins.toyota.car import CarError, NotSignedIn, ToyotaCar
from plugins.toyota.commands import is_confirmed

from .fake_ha import DEVICE, FakeHA, VIN, entity_id, registry, signed_in_ha


def run(coro):
    return asyncio.run(coro)


@pytest.mark.parametrize("name", ["unlock", "trunk_unlock", "start"])
def test_unlock_trunk_and_start_ask_first_and_touch_nothing(name):
    ha = signed_in_ha()
    out = run(ToyotaCar(ha).command(name))
    assert out["needs_confirmation"] is True and out["ask"].endswith("?")
    assert ha.calls == []


@pytest.mark.parametrize("value,expected", [(True, True), ("true", True), (" True ", False), ("TRUE", False),
                                            ("yes", False), (1, False), (None, False), (False, False)])
def test_only_an_explicit_yes_confirms(value, expected):
    assert is_confirmed(value) is expected


def test_a_command_calls_the_integration_service_for_his_car():
    ha = signed_in_ha()
    out = run(ToyotaCar(ha).command("lock"))
    assert out == {"ok": True, "command": "lock", "result": "Locked"}
    assert ha.services() == [("door_lock", {"vehicle": DEVICE})]
    assert ha.registry_reads == 1, "a command always reads the registry fresh"
    run(ToyotaCar(ha).command("lock"))
    assert ha.registry_reads == 2


def test_confirmed_unlock_goes_through():
    ha = signed_in_ha()
    assert run(ToyotaCar(ha).command("unlock", True))["result"] == "Unlocked"
    assert ha.services() == [("door_unlock", {"vehicle": DEVICE})]


def test_a_command_toyota_does_not_confirm_in_time_is_pending():
    from plugins.toyota.car import CommandPending
    from plugins.toyota.ha import HATimeout

    ha = signed_in_ha()
    ha.reply("WS", "call_service", HATimeout("Home Assistant didn't answer within 75 s"))
    with pytest.raises(CommandPending) as err:
        run(ToyotaCar(ha).command("lock"))
    assert err.value.status == 504


def test_refresh_waits_for_the_new_report(monkeypatch):
    import plugins.toyota.car as car_module

    async def no_sleep(_):
        ha.state_map[entity_id("updated")] = {**ha.state_map[entity_id("updated")], "state": "2026-10-08T21:00:00+00:00"}
    monkeypatch.setattr(car_module.asyncio, "sleep", no_sleep)
    ha = signed_in_ha()
    assert run(ToyotaCar(ha).refresh()) == {"ok": True, "fresh": True}
    assert ha.services() == [("refresh", {"vehicle": DEVICE})]


def test_refresh_says_when_no_new_report_came(monkeypatch):
    import plugins.toyota.car as car_module

    now = [0.0]

    async def tick(_):
        now[0] += 5
    monkeypatch.setattr(car_module.asyncio, "sleep", tick)
    assert run(ToyotaCar(signed_in_ha(), clock=lambda: now[0]).refresh())["fresh"] is False


def test_an_unavailable_command_entity_is_not_offered():
    from plugins.toyota.entities import build_map
    from plugins.toyota.snapshot import build_snapshot

    from .fake_ha import camry_states
    states = camry_states()
    states[entity_id("btn_horn")] = {"state": "unavailable", "attributes": {}}
    assert "horn" not in build_snapshot(build_map(registry()), states)["commands"]


def test_unknown_or_unsupported_commands_are_refused():
    with pytest.raises(CarError):
        run(ToyotaCar(signed_in_ha()).command("fly"))
    rows = [r for r in registry() if r["unique_id"] != f"{VIN}.Sound Horn"]
    with pytest.raises(CarError, match="Remote Connect"):
        run(ToyotaCar(signed_in_ha(registry=rows)).command("horn"))


def test_no_car_in_home_assistant_means_sign_in_first():
    with pytest.raises(NotSignedIn):
        run(ToyotaCar(FakeHA()).command("lock"))


def test_the_entity_map_is_cached_then_read_again():
    ha, now = signed_in_ha(), [0.0]
    car = ToyotaCar(ha, clock=lambda: now[0])
    run(car.snapshot()); run(car.snapshot())
    assert ha.registry_reads == 1
    now[0] = 301
    run(car.snapshot())
    assert ha.registry_reads == 2


def test_climate_values_are_all_checked_before_anything_changes():
    ha = signed_in_ha()
    with pytest.raises(CarError, match="60 to 85"):
        run(ToyotaCar(ha).set_climate(temp=95, defrost_front=True))
    with pytest.raises(CarError, match="true or false"):
        run(ToyotaCar(ha).set_climate(defrost_rear="maybe"))
    assert ha.posts() == []


def test_climate_sets_the_number_and_switches():
    ha = signed_in_ha()
    out = run(ToyotaCar(ha).set_climate(temp=70, defrost_front=True, custom=False))
    assert ha.posts() == [
        ("/api/services/number/set_value", {"entity_id": entity_id("climate_temp"), "value": 70.0}),
        ("/api/services/switch/turn_off", {"entity_id": entity_id("climate_custom")}),
        ("/api/services/switch/turn_on", {"entity_id": entity_id("defrost_front")}),
    ]
    assert out["ok"] is True and out["climate"]["unit"] == "°F"
