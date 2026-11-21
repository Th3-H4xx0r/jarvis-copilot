"""PC Lighting tools: Jarvis sets parts, effects, brightness and looks through the server, runs setup
steps, tests LEDs for calibration and reads the map and specs — every control the apps have, never the map write."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

import tools.pc_lighting_tool as t

CONTROLLERS = [{"index": 0, "name": "ASRock B760M-C", "location": "HID: /dev/hidraw0",
                "zones": [{"index": 0, "name": "ARGB 1", "leds": 120, "resizable": True, "max": 300},
                          {"index": 1, "name": "ARGB 2", "leds": 40, "resizable": True, "max": 300},
                          {"index": 2, "name": "RGB", "leds": 1, "resizable": False, "max": 1}]}]
MAPPED = {"device_id": "pc-1", "online": True,
          "state": {"on": True, "brightness": 80, "rev": 3, "t0": 1.0,
                    "parts": {p: {"effect": "static", "color": "#ffffff", "speed": 5}
                              for p in ("top", "rear", "bottom", "cooler", "strip")}},
          "map": {"version": 1, "rev": 2, "zones": [{"controller": 0, "zone": 0, "leds": 120}],
                  "segments": [{"part": "top", "index": 0, "controller": 0, "zone": 0, "start": 0, "count": 16,
                                "also": ["rear", "bottom"]}]},
          "coverage": {"top": None, "rear": "top", "bottom": "top", "cooler": None, "strip": "missing"},
          "setup": {"openrgb": {"id": "openrgb", "state": "done", "detail": "OpenRGB is installed"}},
          "live": {"engine": "running", "error": None, "paused_for_game": False, "controllers": CONTROLLERS}}


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


def _posts(calls):
    return [c for c in calls if c[0] != "GET"]


# ── pc_lights: set (combined) ─────────────────────────────────────────────────
def test_set_with_a_colour_name_posts_hex(api):
    calls, _ = api
    out = _out(t.pc_lights({"action": "set", "part": "top", "color": "red"}))
    assert out["ok"] is True
    assert calls[-1] == ("POST", "/api/pc-lighting/state", {"part": "top", "color": "#ff0000"})


def test_set_defaults_to_the_whole_pc(api):
    calls, _ = api
    t.pc_lights({"action": "set", "effect": "rainbow", "brightness": 40})
    assert calls[-1][2] == {"part": "all", "effect": "rainbow", "brightness": 40}


def test_set_with_nothing_to_change_is_refused(api):
    calls, _ = api
    out = _out(t.pc_lights({"action": "set", "part": "top"}))
    assert out["ok"] is False and not _posts(calls)


def test_unknown_colour_name_is_refused_before_calling(api):
    calls, _ = api
    out = _out(t.pc_lights({"action": "set", "color": "glorp"}))
    assert out["ok"] is False and "colour" in out["error"].lower()
    assert not _posts(calls)


def test_colour_names_ignore_case_dashes_and_underscores(api):
    calls, _ = api
    t.pc_lights({"action": "color", "part": "cooler", "color": "Warm_White"})
    assert calls[-1][2] == {"part": "cooler", "color": t.NAMES["warm white"]}
    t.pc_lights({"action": "color", "color": "FF8800"})
    assert calls[-1][2] == {"part": "all", "color": "#ff8800"}


def test_on_must_be_a_real_boolean(api):
    calls, _ = api
    out = _out(t.pc_lights({"action": "set", "on": "false"}))
    assert out["ok"] is False and not _posts(calls)


def test_offline_reason_comes_from_the_server(api):
    calls, replies = api
    replies[("POST", "/api/pc-lighting/state")] = {"ok": False, "error": "The PC is asleep or offline", "offline": True}
    out = _out(t.pc_lights({"action": "set", "color": "#00ff00"}))
    assert out["ok"] is False and "asleep or offline" in out["error"] and out["offline"] is True


def test_openrgb_down_is_flagged_as_an_engine_error(api):
    calls, replies = api
    replies[("POST", "/api/pc-lighting/state")] = {"ok": False, "engine_error": True,
                                                    "error": "Can't drive the lights through OpenRGB at 127.0.0.1:6742"}
    out = _out(t.pc_lights({"action": "off"}))
    assert out["ok"] is False and out["engine_error"] is True and "OpenRGB" in out["error"]


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


def test_a_mirrored_part_says_its_host_changed_too(api):
    out = _out(t.pc_lights({"action": "color", "part": "rear", "color": "blue"}))
    assert out["ok"] is True and "top" in out["note"]


# ── pc_lights: one action per control ────────────────────────────────────────
def test_on_and_off_switch_the_whole_pc(api):
    calls, _ = api
    t.pc_lights({"action": "off"})
    assert calls[-1] == ("POST", "/api/pc-lighting/state", {"part": "all", "on": False})
    t.pc_lights({"action": "on"})
    assert calls[-1] == ("POST", "/api/pc-lighting/state", {"part": "all", "on": True})


def test_brightness_is_whole_pc_and_bounded(api):
    calls, _ = api
    t.pc_lights({"action": "brightness", "brightness": 30, "part": "top"})
    assert calls[-1][2] == {"part": "all", "brightness": 30}
    n = len(calls)
    for bad in ({"action": "brightness"}, {"action": "brightness", "brightness": 150},
                {"action": "brightness", "brightness": "loud"}):
        assert _out(t.pc_lights(bad))["ok"] is False
    assert not _posts(calls[n:])


def test_color_needs_a_colour_and_targets_one_part(api):
    calls, _ = api
    t.pc_lights({"action": "color", "part": "strip", "color": "purple"})
    assert calls[-1][2] == {"part": "strip", "color": t.NAMES["purple"]}
    n = len(calls)
    assert _out(t.pc_lights({"action": "color", "part": "strip"}))["ok"] is False
    assert not _posts(calls[n:])


def test_effect_needs_an_effect_and_may_carry_a_speed(api):
    calls, _ = api
    t.pc_lights({"action": "effect", "part": "cooler", "effect": "comet", "speed": 8})
    assert calls[-1][2] == {"part": "cooler", "effect": "comet", "speed": 8}
    n = len(calls)
    assert _out(t.pc_lights({"action": "effect", "effect": "disco"}))["ok"] is False
    assert _out(t.pc_lights({"action": "effect"}))["ok"] is False
    assert not _posts(calls[n:])


def test_speed_is_per_part_and_bounded(api):
    calls, _ = api
    t.pc_lights({"action": "speed", "part": "top", "speed": 2})
    assert calls[-1][2] == {"part": "top", "speed": 2}
    n = len(calls)
    assert _out(t.pc_lights({"action": "speed", "speed": 0}))["ok"] is False
    assert _out(t.pc_lights({"action": "speed", "speed": 11}))["ok"] is False
    assert not _posts(calls[n:])


def test_unknown_part_and_action_are_refused(api):
    calls, _ = api
    assert _out(t.pc_lights({"action": "color", "part": "gpu", "color": "red"}))["ok"] is False
    assert _out(t.pc_lights({"action": "dance"}))["ok"] is False
    assert not _posts(calls)


# ── pc_lights: status ────────────────────────────────────────────────────────
def test_status_summarises_the_parts(api):
    out = _out(t.pc_lights({"action": "status"}))
    assert out["ok"] is True and out["brightness"] == 80 and out["parts"]["top"]["effect"] == "static"


def test_status_says_which_parts_have_lights_mirror_or_have_none(api):
    out = _out(t.pc_lights({"action": "status"}))
    assert out["online"] is True and out["engine"] == "running" and out["paused_for_game"] is False
    assert out["parts"]["top"]["lights"] == "own"
    assert "top" in out["parts"]["rear"]["lights"] and "top" in out["parts"]["bottom"]["lights"]
    assert out["parts"]["strip"]["lights"] == "none"


def test_status_shows_what_a_mirrored_part_really_displays(api):
    calls, replies = api
    st = json.loads(json.dumps(MAPPED["state"]))
    st["parts"]["top"]["color"] = "#ff0000"
    replies[("GET", "/api/pc-lighting")] = dict(MAPPED, state=st)
    out = _out(t.pc_lights({"action": "status"}))
    assert out["parts"]["rear"]["color"] == "#ff0000"


def test_status_reports_the_engine_error(api):
    calls, replies = api
    replies[("GET", "/api/pc-lighting")] = dict(MAPPED, live={"engine": "error", "error": "OpenRGB refused",
                                                             "paused_for_game": False, "controllers": []})
    out = _out(t.pc_lights({"action": "status"}))
    assert out["ok"] is True and out["engine"] == "error" and out["engine_error"] == "OpenRGB refused"


# ── pc_light_looks ───────────────────────────────────────────────────────────
def test_looks_apply_save_list_delete(api):
    calls, replies = api
    replies[("GET", "/api/pc-lighting/looks")] = {"looks": [{"name": "Late night"}]}
    t.pc_light_looks({"action": "save", "name": "Gaming"})
    assert calls[-1] == ("POST", "/api/pc-lighting/looks", {"name": "Gaming"})
    t.pc_light_looks({"action": "apply", "name": "Gaming"})
    assert calls[-1] == ("POST", "/api/pc-lighting/looks/apply", {"name": "Gaming"})
    t.pc_light_looks({"action": "delete", "name": "Late night"})
    assert calls[-1] == ("DELETE", "/api/pc-lighting/looks/Late%20night", None)
    t.pc_light_looks({"action": "list"})
    assert calls[-1] == ("GET", "/api/pc-lighting/looks", None)


def test_looks_need_a_name_to_save_apply_or_delete(api):
    calls, _ = api
    for action in ("save", "apply", "delete"):
        assert _out(t.pc_light_looks({"action": action}))["ok"] is False
    assert not _posts(calls)


def test_deleting_a_look_that_is_not_there_names_the_ones_that_are(api):
    calls, replies = api
    replies[("GET", "/api/pc-lighting/looks")] = {"looks": [{"name": "Gaming"}]}
    out = _out(t.pc_light_looks({"action": "delete", "name": "Nope"}))
    assert out["ok"] is False and "Gaming" in out["error"] and not _posts(calls)


# ── pc_light_setup ───────────────────────────────────────────────────────────
def _routes():
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))
    import api.pc_lighting_routes as routes
    return routes


def test_steps_lists_every_server_step_in_order_with_its_state(api):
    out = _out(t.pc_light_setup({"action": "steps"}))
    assert out["ok"] is True
    assert [s["id"] for s in out["steps"]] == list(_routes().SETUP_STEPS)
    by_id = {s["id"]: s for s in out["steps"]}
    assert by_id["openrgb"]["state"] == "done" and by_id["detect"]["state"] == "todo"
    assert all(s["what"] for s in out["steps"])


def test_run_step_posts_it_and_says_it_runs_in_the_background(api):
    calls, replies = api
    replies[("POST", "/api/pc-lighting/setup")] = {"ok": True, "step": {"id": "detect", "state": "running"}}
    out = _out(t.pc_light_setup({"action": "run_step", "step": "detect"}))
    assert calls[-1] == ("POST", "/api/pc-lighting/setup", {"step": "detect"})
    assert out["ok"] is True and out["step"]["state"] == "running" and out["note"]


def test_installing_steps_say_face_id_will_ask(api):
    calls, replies = api
    replies[("POST", "/api/pc-lighting/setup")] = {"ok": True, "step": {"id": "openrgb", "state": "running"}}
    out = _out(t.pc_light_setup({"action": "run_step", "step": "openrgb"}))
    assert "Face ID" in out["note"]


def test_calibration_is_left_to_the_iphone(api):
    calls, _ = api
    out = _out(t.pc_light_setup({"action": "run_step", "step": "calibrate"}))
    assert out["ok"] is False and "iPhone" in out["error"] and not _posts(calls)


def test_unknown_step_is_refused_before_calling(api):
    calls, _ = api
    assert _out(t.pc_light_setup({"action": "run_step", "step": "format"}))["ok"] is False
    assert _out(t.pc_light_setup({"action": "run_step"}))["ok"] is False
    assert not _posts(calls)


def test_connectors_list_controllers_zones_led_counts_and_mapped_parts(api):
    out = _out(t.pc_light_setup({"action": "connectors"}))
    assert out["ok"] is True
    (ctl,) = out["connectors"]
    assert ctl["controller"] == 0 and ctl["name"] == "ASRock B760M-C"
    zone0 = ctl["zones"][0]
    assert zone0["zone"] == 0 and zone0["leds"] == 120 and zone0["resizable"] is True
    assert zone0["parts"][0]["part"] == "top" and zone0["parts"][0]["also"] == ["rear", "bottom"]


def test_no_connectors_says_why(api):
    calls, replies = api
    replies[("GET", "/api/pc-lighting")] = dict(MAPPED, live={"engine": "error", "error": "OpenRGB refused",
                                                             "controllers": []})
    out = _out(t.pc_light_setup({"action": "connectors"}))
    assert out["ok"] is True and out["connectors"] == [] and "OpenRGB refused" in out["note"]


def test_test_leds_lights_a_range_in_a_colour(api):
    calls, _ = api
    out = _out(t.pc_light_setup({"action": "test_leds", "controller": 0, "zone": 1, "start": 10, "count": 5,
                                 "color": "red"}))
    assert out["ok"] is True
    assert calls[-1] == ("POST", "/api/pc-lighting/probe",
                         {"controller": 0, "zone": 1, "range": [10, 5], "color": "#ff0000"})


def test_test_leds_defaults_to_one_white_led(api):
    calls, _ = api
    t.pc_light_setup({"action": "test_leds", "controller": 0, "zone": 0, "start": 7})
    assert calls[-1][2] == {"controller": 0, "zone": 0, "range": [7, 1], "color": "#ffffff"}


def test_test_leds_refuses_a_connector_or_leds_that_do_not_exist(api):
    calls, _ = api
    for bad in ({"controller": 3, "zone": 0}, {"controller": 0, "zone": 9}, {"controller": 0, "zone": 1,
                                                                             "start": 38, "count": 5},
                {"zone": 0}, {"controller": 0, "zone": 0, "count": 0}, {"controller": 0, "zone": 0, "color": "glorp"}):
        out = _out(t.pc_light_setup(dict(bad, action="test_leds")))
        assert out["ok"] is False, bad
    assert not _posts(calls)


def test_probe_failure_is_reported(api):
    calls, replies = api
    replies[("POST", "/api/pc-lighting/probe")] = {"ok": False, "error": "OpenRGB isn't connected"}
    out = _out(t.pc_light_setup({"action": "test_leds", "controller": 0, "zone": 0}))
    assert out["ok"] is False and "OpenRGB" in out["error"]


def test_led_count_resizes_a_resizable_connector_and_lights_that_many(api):
    calls, _ = api
    out = _out(t.pc_light_setup({"action": "led_count", "controller": 0, "zone": 1, "count": 54}))
    assert out["ok"] is True
    assert calls[-1] == ("POST", "/api/pc-lighting/probe",
                         {"controller": 0, "zone": 1, "resize": 54, "range": [0, 54]})


def test_led_count_refuses_fixed_zones_and_counts_past_the_maximum(api):
    calls, _ = api
    assert _out(t.pc_light_setup({"action": "led_count", "controller": 0, "zone": 2, "count": 4}))["ok"] is False
    assert _out(t.pc_light_setup({"action": "led_count", "controller": 0, "zone": 0, "count": 301}))["ok"] is False
    assert _out(t.pc_light_setup({"action": "led_count", "controller": 0, "zone": 0}))["ok"] is False
    assert not _posts(calls)


def test_clear_test_puts_the_lights_back(api):
    calls, _ = api
    out = _out(t.pc_light_setup({"action": "clear_test"}))
    assert out["ok"] is True and calls[-1] == ("POST", "/api/pc-lighting/probe", {"clear": True})


def test_map_is_read_only_with_coverage(api):
    calls, _ = api
    out = _out(t.pc_light_setup({"action": "map"}))
    assert out["ok"] is True and out["map"]["segments"][0]["part"] == "top"
    assert out["coverage"]["rear"] == "top" and out["coverage"]["strip"] == "missing"
    assert not _posts(calls)


def test_specs_read_and_refresh(api):
    calls, replies = api
    replies[("GET", "/api/pc-specs")] = {"device_id": "pc-1", "specs": {"read_at": 5.0,
                                                                        "board": {"product": "B760M-C"}}}
    out = _out(t.pc_light_setup({"action": "specs"}))
    assert out["ok"] is True and out["specs"]["board"]["product"] == "B760M-C"
    replies[("POST", "/api/pc-specs/refresh")] = {"ok": True, "specs": {"read_at": 9.0, "cpu": {"name": "i7"}}}
    out = _out(t.pc_light_setup({"action": "refresh_specs"}))
    assert out["ok"] is True and out["specs"]["cpu"]["name"] == "i7"
    assert calls[-1][:2] == ("POST", "/api/pc-specs/refresh")


def test_specs_not_read_yet_says_how(api):
    calls, replies = api
    replies[("GET", "/api/pc-specs")] = {"device_id": "pc-1", "specs": None}
    out = _out(t.pc_light_setup({"action": "specs"}))
    assert out["ok"] is True and out["specs"] is None and "refresh_specs" in out["note"]


# ── contracts ────────────────────────────────────────────────────────────────
def _schema(name):
    from tools.registry import registry
    return registry.get_schema(name)


@pytest.mark.parametrize("name", ["pc_lights", "pc_light_looks", "pc_light_setup"])
def test_every_action_in_the_schema_is_handled(api, name):
    actions = _schema(name)["parameters"]["properties"]["action"]["enum"]
    fn = getattr(t, name)
    for action in actions:
        out = _out(fn({"action": action}))
        assert "unknown action" not in str(out.get("error", "")).lower(), (name, action)


def test_no_tool_writes_the_led_map(api):
    calls, _ = api
    for name in ("pc_lights", "pc_light_looks", "pc_light_setup"):
        for action in _schema(name)["parameters"]["properties"]["action"]["enum"]:
            getattr(t, name)({"action": action, "name": "x", "step": "detect", "controller": 0, "zone": 0,
                              "count": 4, "color": "red", "effect": "static", "speed": 5, "brightness": 50})
    assert not [c for c in calls if c[0] == "PUT" or c[1].endswith("/map")]


def test_parts_and_effects_match_the_store():
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))
    import api.pc_lighting_store as store
    assert set(t.PARTS) == set(store.PARTS) | {"all"}
    assert set(t.EFFECTS) == set(store.EFFECTS)


def test_tools_are_in_the_pc_lighting_toolset():
    from tools.registry import registry
    from toolsets import TOOLSETS, _HERMES_CORE_TOOLS
    for name in ("pc_lights", "pc_light_looks", "pc_light_setup"):
        assert registry.get_toolset_for_tool(name) == "pc_lighting"
        assert name in TOOLSETS["pc_lighting"]["tools"] and name in _HERMES_CORE_TOOLS


def test_named_colours_light_the_leds_at_full_strength():
    # The PC turns screen colours into LED power: a name whose strongest channel is under full looks
    # dim on the fans (web "green" #008000 is half power). Off and the greys are dim on purpose.
    for name, value in t.NAMES.items():
        if name in ("black", "gray", "grey", "silver"):
            continue
        assert max(int(value[i:i + 2], 16) for i in (1, 3, 5)) == 255, name
