"""The entity map and the car snapshot: what the Car page and toyota_status show."""
from plugins.toyota.entities import build_map
from plugins.toyota.snapshot import build_snapshot

from .fake_ha import DEVICE, VIN, camry_states, entity_id, registry


def snap(rows=None, states=None):
    m = build_map(rows if rows is not None else registry())
    return build_snapshot(m, states if states is not None else camry_states())


def test_snapshot_matches_his_toyota_app():
    s = snap()
    assert (s["range_mi"], s["fuel_pct"], s["odometer_mi"]) == (353, 62.0, 63)
    assert (s["tires"]["fl"], s["tires"]["fr"], s["tires"]["rl"], s["tires"]["rr"]) == (36, 36, 35, 36)
    assert s["tires"]["warnings"] == []
    assert s["doors"] == {"open": [], "locked": True}
    assert s["windows"]["open"] == [] and s["trunk"] == {"open": [], "locked": True}
    assert s["climate"]["temp"] == 68 and s["climate"]["custom"] is True and s["climate"]["max"] == 85
    assert s["location"]["lat"] == 37.3349 and s["vin_last4"] == VIN[-4:]
    assert s["running"] is False
    assert {"start", "lock", "unlock", "horn", "hazards_off"} <= set(s["commands"])


def test_found_by_unique_id_even_when_he_renames_entities():
    rows = registry()
    for row in rows:
        row["entity_id"] = row["entity_id"].replace("camry_", "my_car_renamed_")
    states = {k.replace("camry_", "my_car_renamed_"): {**v, "entity_id": k.replace("camry_", "my_car_renamed_")}
              for k, v in camry_states().items()}
    assert snap(rows, states)["range_mi"] == 353


def test_other_integrations_and_disabled_entities_are_ignored():
    rows = registry(fuel={"disabled_by": "user"})
    rows.append({"entity_id": "sensor.camry_fuel_level_other", "platform": "other", "unique_id": f"{VIN}.Fuel Level"})
    m = build_map(rows)
    assert not m.has("fuel") and m.device_id == DEVICE
    assert snap(rows)["fuel_pct"] is None


def test_no_toyota_entities_means_no_car():
    assert build_map([{"entity_id": "light.kitchen", "platform": "hue", "unique_id": "x.y"}]) is None


def test_metric_home_assistant_is_converted_to_miles_and_psi():
    s = snap(states=camry_states(odometer=("101", "km"), range=("568", "km"), tire_fl=("248", "kPa")))
    assert s["odometer_mi"] == 63 and s["range_mi"] == 353 and s["tires"]["fl"] == 36.0


def test_unknown_readings_are_empty_and_missing_parts_hidden():
    rows = [r for r in registry() if not r["unique_id"].endswith(".Hood")]
    s = snap(rows, camry_states(fuel=("unavailable", None), lock=("unknown", None)))
    assert s["fuel_pct"] is None and s["hood"] is None
    # No lock reading: the per-door lock sensors decide (all off = locked).
    assert s["doors"]["locked"] is True


def test_open_door_window_and_tire_warning_show_up():
    s = snap(states=camry_states(door_fl=("on", None), window_rr=("on", None), tire_warn_rl=("on", None)))
    assert s["doors"]["open"] == ["Front Driver"] and s["windows"]["open"] == ["Rear Passenger"]
    tires = next(h for h in s["health"] if h["id"] == "tires")
    assert tires["ok"] is False and "rear driver" in tires["detail"]


def test_commands_follow_what_the_car_supports():
    rows = [r for r in registry() if r["unique_id"] != f"{VIN}.Sound Horn"]
    assert "horn" not in snap(rows)["commands"]


def test_oil_and_key_fob_join_health_when_reported():
    rows = registry() + [{"entity_id": "binary_sensor.camry_key_fob_battery", "platform": "toyota_na",
                          "unique_id": f"{VIN}.Key Fob Battery", "device_id": DEVICE}]
    states = camry_states()
    states["binary_sensor.camry_key_fob_battery"] = {"state": "on", "attributes": {}}
    fob = next(h for h in snap(rows, states)["health"] if h["title"] == "Key Fob Battery")
    assert fob["ok"] is False


def test_the_car_with_most_entities_wins():
    rows = registry() + registry(roles=["fuel"], vin="OTHERVIN000000001")
    assert build_map(rows).vin == VIN
