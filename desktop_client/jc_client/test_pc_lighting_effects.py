"""Lighting effects: the maths the PC renders and the iPhone mirrors (golden fixtures keep both in step)."""
import json
from pathlib import Path

import pytest

from jc_client.pc_lighting import effects

GOLDEN = Path(effects.__file__).with_name("golden.json")


def _state(**parts):
    base = {"effect": "static", "color": "#ffffff", "speed": 5}
    return {"on": True, "brightness": 100, "t0": 1000.0, "frozen_at": None, "still_in_games": False,
            "parts": {p: dict(base, **parts.get(p, {})) for p in ("top", "rear", "bottom", "cooler", "strip")}}


def _map(segments, zones=None):
    return {"version": 1, "rev": 1, "zones": zones or [{"controller": 0, "zone": 0, "leds": 20}], "segments": segments}


def test_golden_cases_match_within_one():
    cases = json.loads(GOLDEN.read_text())
    assert len(cases) >= 40
    for c in cases:
        got = effects.colour(c["effect"], c["color"], c["speed"], c["seg_ord"], c["i"], c["n"], c["t"])
        assert all(abs(a - b) <= 1 for a, b in zip(got, c["rgb"])), c


def test_off_is_all_black():
    st = _state()
    st["on"] = False
    seg = [{"part": "top", "index": 0, "controller": 0, "zone": 0, "start": 0, "count": 20}]
    frame = effects.frame(st, _map(seg), 1005.0)
    assert frame[(0, 0)] == [(0, 0, 0)] * 20


def test_brightness_half_halves_static_white():
    st = _state()
    st["brightness"] = 50
    seg = [{"part": "top", "index": 0, "controller": 0, "zone": 0, "start": 0, "count": 20}]
    r, g, b = effects.frame(st, _map(seg), 1005.0)[(0, 0)][3]
    assert all(abs(v - 128) <= 1 for v in (r, g, b))


def test_frozen_frame_does_not_move():
    st = _state(top={"effect": "rainbow"})
    st["frozen_at"] = 1003.5
    seg = [{"part": "top", "index": 0, "controller": 0, "zone": 0, "start": 0, "count": 20}]
    assert effects.frame(st, _map(seg), 1010.0) == effects.frame(st, _map(seg), 1011.0)


def test_rainbow_moves_when_not_frozen():
    st = _state(top={"effect": "rainbow"})
    seg = [{"part": "top", "index": 0, "controller": 0, "zone": 0, "start": 0, "count": 20}]
    assert effects.frame(st, _map(seg), 1010.0) != effects.frame(st, _map(seg), 1011.0)


def test_led_outside_every_segment_is_black():
    seg = [{"part": "strip", "index": 0, "controller": 0, "zone": 0, "start": 2, "count": 5}]
    frame = effects.frame(_state(), _map(seg), 1005.0)[(0, 0)]
    assert frame[0] == (0, 0, 0) and frame[7] == (0, 0, 0)
    assert frame[2] == (255, 255, 255) and frame[6] == (255, 255, 255)


def test_each_part_uses_its_own_settings():
    st = _state(top={"color": "#ff0000"}, strip={"color": "#0000ff"})
    segs = [{"part": "top", "index": 0, "controller": 0, "zone": 0, "start": 0, "count": 10},
            {"part": "strip", "index": 0, "controller": 0, "zone": 0, "start": 10, "count": 10}]
    frame = effects.frame(st, _map(segs), 1005.0)[(0, 0)]
    assert frame[0] == (255, 0, 0) and frame[15] == (0, 0, 255)


def test_every_zone_in_the_map_gets_a_frame():
    zones = [{"controller": 0, "zone": 0, "leds": 4}, {"controller": 0, "zone": 2, "leds": 3}]
    seg = [{"part": "cooler", "index": 0, "controller": 0, "zone": 2, "start": 0, "count": 3}]
    frame = effects.frame(_state(), _map(seg, zones), 1005.0)
    assert frame[(0, 0)] == [(0, 0, 0)] * 4
    assert frame[(0, 2)] == [(255, 255, 255)] * 3


def test_unknown_effect_raises():
    with pytest.raises(ValueError):
        effects.colour("lava", "#ffffff", 5, 0, 0, 10, 0.0)
