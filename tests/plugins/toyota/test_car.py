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


@pytest.mark.parametrize("value,expected", [(True, True), ("true", True), (" True ", True),
                                            ("yes", False), (1, False), (None, False), (False, False)])
def test_only_an_explicit_yes_confirms(value, expected):
    assert is_confirmed(value) is expected


def test_a_command_calls_the_integration_service_for_his_car():
    ha = signed_in_ha()
    out = run(ToyotaCar(ha).command("lock"))
    assert out == {"ok": True, "command": "lock", "result": "Locked"}
    assert ha.posts() == [("/api/services/toyota_na/door_lock", {"vehicle": DEVICE})]


def test_confirmed_unlock_goes_through():
    ha = signed_in_ha()
    assert run(ToyotaCar(ha).command("unlock", True))["result"] == "Unlocked"
    assert ha.posts() == [("/api/services/toyota_na/door_unlock", {"vehicle": DEVICE})]


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
