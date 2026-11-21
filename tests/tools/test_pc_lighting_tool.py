"""PC Lighting tools: Jarvis sets parts, effects, brightness and looks through the server."""
from __future__ import annotations

import json

import pytest

import tools.pc_lighting_tool as t

MAPPED = {"device_id": "pc-1", "online": True,
          "state": {"on": True, "brightness": 80, "parts": {p: {"effect": "static", "color": "#ffffff", "speed": 5}
                                                           for p in ("top", "rear", "bottom", "cooler", "strip")}},
          "map": {"segments": [{"part": "top"}]}, "coverage": {"top": None}, "live": {"engine": "running"}}


@pytest.fixture
def api(monkeypatch):
    calls, replies = [], {}

    def fake(method, path, body=None, timeout=10.0):
        calls.append((method, path, body))
        return replies.get((method, path), MAPPED if method == "GET" else {"ok": True, "state": MAPPED["state"]})

    monkeypatch.setattr(t, "_api_request", fake)
    return calls, replies


def _out(s):
    return json.loads(s)


def test_set_with_a_colour_name_posts_hex(api):
    calls, _ = api
    out = _out(t.pc_lights({"action": "set", "part": "top", "color": "red"}))
    assert out["ok"] is True
    assert calls[-1] == ("POST", "/api/pc-lighting/state", {"part": "top", "color": "#ff0000"})


def test_set_defaults_to_the_whole_pc(api):
    calls, _ = api
    t.pc_lights({"action": "set", "effect": "rainbow", "brightness": 40})
    assert calls[-1][2] == {"part": "all", "effect": "rainbow", "brightness": 40}


def test_unknown_colour_name_is_refused_before_calling(api):
    calls, _ = api
    out = _out(t.pc_lights({"action": "set", "color": "glorp"}))
    assert out["ok"] is False and "colour" in out["error"].lower()
    assert not any(c[0] == "POST" for c in calls)


def test_offline_reason_comes_from_the_server(api):
    calls, replies = api
    replies[("POST", "/api/pc-lighting/state")] = {"ok": False, "error": "The PC is asleep or offline", "offline": True}
    out = _out(t.pc_lights({"action": "set", "color": "#00ff00"}))
    assert out["ok"] is False and "asleep or offline" in out["error"]


def test_a_part_with_no_lights_comes_back_as_the_reason(api):
    calls, replies = api
    replies[("POST", "/api/pc-lighting/state")] = {"ok": False, "error": "The strip has no lights mapped"}
    out = _out(t.pc_lights({"action": "set", "part": "strip", "color": "red"}))
    assert out["ok"] is False and out["error"] == "The strip has no lights mapped"


def test_not_set_up_says_where_to_finish(api):
    calls, replies = api
    replies[("GET", "/api/pc-lighting")] = dict(MAPPED, map={"segments": []})
    out = _out(t.pc_lights({"action": "set", "color": "blue"}))
    assert out["ok"] is False and "isn't set up yet" in out["error"] and "iPhone" in out["error"]


def test_status_summarises_the_parts(api):
    out = _out(t.pc_lights({"action": "status"}))
    assert out["ok"] is True and out["brightness"] == 80 and out["parts"]["top"]["effect"] == "static"


def test_looks_apply_save_list_delete(api):
    calls, _ = api
    t.pc_light_looks({"action": "save", "name": "Gaming"})
    assert calls[-1] == ("POST", "/api/pc-lighting/looks", {"name": "Gaming"})
    t.pc_light_looks({"action": "apply", "name": "Gaming"})
    assert calls[-1] == ("POST", "/api/pc-lighting/looks/apply", {"name": "Gaming"})
    t.pc_light_looks({"action": "delete", "name": "Late night"})
    assert calls[-1] == ("DELETE", "/api/pc-lighting/looks/Late%20night", None)
    t.pc_light_looks({"action": "list"})
    assert calls[-1] == ("GET", "/api/pc-lighting/looks", None)


def test_tools_are_in_the_pc_lighting_toolset():
    from tools.registry import registry
    assert registry.get_toolset_for_tool("pc_lights") == "pc_lighting"
    assert registry.get_toolset_for_tool("pc_light_looks") == "pc_lighting"
