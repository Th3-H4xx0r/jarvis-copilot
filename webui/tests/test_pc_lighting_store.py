"""PC lighting store: per-PC state, LED map, looks, setup, specs (server canonical)."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from api.pc_lighting_store import PARTS, PcLightingStore, validate_map  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 1_800_000_000.0

    def __call__(self):
        return self.t


@pytest.fixture()
def st(tmp_path):
    return PcLightingStore(tmp_path / "pcl", clock=Clock())


def _seg(part, index=0, zone=0, start=0, count=10, **kw):
    return {"part": part, "index": index, "controller": 0, "zone": zone, "start": start, "count": count, **kw}


def _map(*segs, leds=60, zones=1):
    return {"version": 1, "zones": [{"controller": 0, "zone": z, "leds": leds} for z in range(zones)],
            "segments": list(segs)}


def test_default_state_is_white_static_on(st):
    s = st.state("pc-1")
    assert s["on"] is True and s["brightness"] == 100 and s["rev"] == 0
    assert set(s["parts"]) == set(PARTS)
    assert all(p == {"effect": "static", "color": "#ffffff", "speed": 5} for p in s["parts"].values())


def test_all_sets_every_part_and_bumps_rev(st):
    s = st.update_state("pc-1", {"part": "all", "color": "#ff0000"})
    assert all(p["color"] == "#ff0000" for p in s["parts"].values()) and s["rev"] == 1


def test_one_part_only_changes_that_part(st):
    s = st.update_state("pc-1", {"part": "strip", "effect": "rainbow"})
    assert s["parts"]["strip"]["effect"] == "rainbow" and s["parts"]["top"]["effect"] == "static"


@pytest.mark.parametrize("bad", [{"part": "all", "color": "red"}, {"part": "all", "color": "#12345"},
                                 {"part": "lava", "color": "#ffffff"}, {"part": "all", "effect": "lava"}])
def test_bad_input_raises(st, bad):
    with pytest.raises(ValueError):
        st.update_state("pc-1", bad)


def test_speed_and_brightness_are_clamped(st):
    s = st.update_state("pc-1", {"part": "top", "speed": 99, "brightness": 140})
    assert s["parts"]["top"]["speed"] == 10 and s["brightness"] == 100
    s = st.update_state("pc-1", {"part": "top", "speed": -3, "brightness": -5})
    assert s["parts"]["top"]["speed"] == 1 and s["brightness"] == 0


def test_t0_resets_on_effect_change_only(st):
    t0 = st.state("pc-1")["t0"]
    st._clock.t += 50
    assert st.update_state("pc-1", {"part": "top", "color": "#00ff00"})["t0"] == t0
    st._clock.t += 50
    assert st.update_state("pc-1", {"part": "top", "effect": "comet"})["t0"] == st._clock.t


def test_state_survives_a_new_store(st, tmp_path):
    st.update_state("pc-1", {"part": "all", "color": "#0000ff"})
    again = PcLightingStore(tmp_path / "pcl", clock=Clock())
    assert again.state("pc-1")["parts"]["top"]["color"] == "#0000ff" and again.devices() == ["pc-1"]


def test_looks_round_trip(st):
    st.update_state("pc-1", {"part": "all", "effect": "rainbow", "brightness": 65})
    st.save_look("pc-1", "Gaming")
    st.update_state("pc-1", {"part": "all", "effect": "static", "brightness": 10})
    s = st.apply_look("pc-1", "Gaming")
    assert s["parts"]["top"]["effect"] == "rainbow" and s["brightness"] == 65
    assert [l["name"] for l in st.looks("pc-1")] == ["Gaming"]
    assert st.delete_look("pc-1", "Gaming") is True and st.looks("pc-1") == []


def test_apply_unknown_look_raises(st):
    with pytest.raises(KeyError):
        st.apply_look("pc-1", "Nope")


def test_set_map_bumps_rev(st):
    m = st.set_map("pc-1", _map(_seg("top")))
    assert m["rev"] == 1 and st.set_map("pc-1", _map(_seg("top")))["rev"] == 2


def test_validate_map_rejects_overlaps_unknown_parts_and_bad_ranges():
    assert validate_map(_map(_seg("top", start=0, count=10), _seg("rear", start=5, count=10)))
    assert validate_map(_map(_seg("lava")))
    assert validate_map(_map(_seg("top", count=0)))
    assert validate_map(_map(_seg("top", index=2)))            # top has 2 fans: 0 and 1
    assert validate_map(_map(_seg("top", start=55, count=10)))  # past the zone's 60 LEDs
    assert validate_map(_map(_seg("top", zone=3)))              # zone not in the map
    assert validate_map(_map(_seg("top"), _seg("top", start=20)))   # same fan twice
    assert validate_map(_map(_seg("top", also=["top"])))
    assert validate_map(_map(_seg("top"), _seg("rear", start=10), _seg("strip", start=20, count=30))) == []


def test_zone_colour_order_must_be_a_channel_order():
    ok = _map(_seg("top"))
    ok["zones"][0]["order"] = "grb"
    assert validate_map(ok) == []
    bad = _map(_seg("top"))
    bad["zones"][0]["order"] = "rrg"
    assert validate_map(bad)


def test_coverage_own_shared_missing(st):
    st.set_map("pc-1", _map(_seg("top"), _seg("bottom", start=10, also=["rear"])))
    cov = st.coverage("pc-1")
    assert cov["top"] is None and cov["bottom"] is None
    assert cov["rear"] == "bottom" and cov["cooler"] == "missing" and cov["strip"] == "missing"


def test_specs_and_setup_steps_are_kept(st):
    st.set_specs("pc-1", {"read_at": 1.0, "board": {"product": "B760M-C"}})
    assert st.specs("pc-1")["board"]["product"] == "B760M-C"
    st.set_setup_step("pc-1", {"id": "detect", "state": "done", "detail": "1 controller"})
    assert st.setup("pc-1")["detect"]["state"] == "done"
