"""PC lighting over HTTP + bridge events: state/looks/map/probe/setup, offline 409s, reconnect resync."""
from __future__ import annotations

import io
import sys
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.pc_lighting_routes as routes  # noqa: E402
import api.pc_specs_routes as specs_routes  # noqa: E402
from api.pc_lighting_store import PcLightingStore  # noqa: E402


@pytest.fixture()
def env(tmp_path, monkeypatch):
    st = PcLightingStore(tmp_path / "pcl", clock=lambda: 1_800_000_000.0)
    calls, published, online = [], [], {"ids": ["pc-1"]}
    replies = {}

    def invoke(did, skill, args, timeout=15.0):
        calls.append((did, skill, args, timeout))
        return replies.get(skill, {"ok": True, "result": {"ok": True}})

    monkeypatch.setattr(routes, "store", lambda: st)
    monkeypatch.setattr(specs_routes, "store", lambda: st)
    monkeypatch.setattr(routes, "_invoke", invoke)
    monkeypatch.setattr(specs_routes, "_invoke", invoke)
    monkeypatch.setattr(routes, "_connected", lambda: list(online["ids"]))
    monkeypatch.setattr(routes, "_device_os", lambda did: "windows")
    monkeypatch.setattr(routes, "_publish", lambda topic, data: published.append((topic, data)))
    monkeypatch.setattr(routes, "_settings", lambda: {"address": "127.0.0.1:6742"})
    monkeypatch.setattr(routes, "_enabled", lambda: True)
    monkeypatch.setattr(routes, "_sensor_driver", lambda: True)
    monkeypatch.setattr(routes, "_spawn", lambda fn, *a: fn(*a))
    return SimpleNamespace(st=st, calls=calls, published=published, online=online, replies=replies)


def call(mod, prefix, method, path, body=None):
    box = {}
    parsed = urlparse(path)
    req = SimpleNamespace(method=method, path=parsed.path, parsed=parsed, body=body, host_signed=False,
                          prefix=prefix, handler=SimpleNamespace(rfile=io.BytesIO(b""), headers={}),
                          sub=parsed.path[len(prefix):], device={"id": "iphone"}, query=parse_qs(parsed.query))
    req.reply = lambda status, payload: box.update(status=status, body=payload) or True
    assert mod.route(req) is not False
    return box["status"], box["body"]


def light(method, path, body=None):
    return call(routes, "/api/pc-lighting", method, path, body)


def _skills(env, name):
    return [c for c in env.calls if c[1] == name]


MAP = {"version": 1, "zones": [{"controller": 0, "zone": 0, "leds": 60}],
       "segments": [{"part": "top", "index": 0, "controller": 0, "zone": 0, "start": 0, "count": 16},
                    {"part": "bottom", "index": 0, "controller": 0, "zone": 0, "start": 16, "count": 16,
                     "also": ["rear"]}]}


def test_get_returns_everything_a_device_draws(env):
    status, body = light("GET", "/api/pc-lighting")
    assert status == 200 and body["device_id"] == "pc-1" and body["online"] is True
    assert {"state", "map", "looks", "setup", "coverage", "live", "address"} <= set(body)


def test_post_state_stores_pushes_and_publishes(env):
    status, body = light("POST", "/api/pc-lighting/state", {"part": "all", "color": "#ff0000"})
    assert status == 200 and body["state"]["parts"]["top"]["color"] == "#ff0000"
    (did, _, args, _t), = _skills(env, "lighting_state_set")
    assert did == "pc-1" and args["rev"] == 1 and args["address"] == "127.0.0.1:6742" and args["enabled"] is True
    assert args["state"]["parts"]["strip"]["color"] == "#ff0000"
    assert env.published and env.published[-1][0] == "pc_lighting"


def test_offline_pc_gets_409_and_nothing_changes(env):
    env.online["ids"] = []
    status, body = light("POST", "/api/pc-lighting/state", {"part": "all", "color": "#ff0000"})
    assert status == 409 and body["offline"] is True and "asleep or offline" in body["error"]
    assert env.st.state("pc-1")["rev"] == 0 and not env.calls


def test_bad_state_is_400(env):
    status, body = light("POST", "/api/pc-lighting/state", {"part": "all", "color": "red"})
    assert status == 400 and "colour" in body["error"]


def test_pc_refusing_the_change_is_502_with_its_reason(env):
    env.replies["lighting_state_set"] = {"ok": False, "error": "device has no skill named 'lighting_state_set'"}
    status, body = light("POST", "/api/pc-lighting/state", {"part": "top", "color": "#00ff00"})
    assert status == 502 and "Update Jarvis on the PC" in body["error"]


def test_a_shared_part_sets_its_host_too(env):
    env.st.set_map("pc-1", MAP)
    light("POST", "/api/pc-lighting/state", {"part": "rear", "color": "#123456"})
    s = env.st.state("pc-1")
    assert s["parts"]["rear"]["color"] == "#123456" and s["parts"]["bottom"]["color"] == "#123456"


def test_looks_save_apply_delete(env):
    light("POST", "/api/pc-lighting/state", {"part": "all", "effect": "rainbow"})
    status, _ = light("POST", "/api/pc-lighting/looks", {"name": "Gaming"})
    assert status == 200
    light("POST", "/api/pc-lighting/state", {"part": "all", "effect": "static"})
    status, body = light("POST", "/api/pc-lighting/looks/apply", {"name": "Gaming"})
    assert status == 200 and body["state"]["parts"]["top"]["effect"] == "rainbow"
    assert light("POST", "/api/pc-lighting/looks/apply", {"name": "Nope"})[0] == 404
    status, body = light("DELETE", "/api/pc-lighting/looks/Gaming")
    assert status == 200 and body["looks"] == []


def test_map_put_validates_pushes_and_marks_calibration(env):
    bad = dict(MAP, segments=[dict(MAP["segments"][0], count=0)])
    status, body = light("PUT", "/api/pc-lighting/map", bad)
    assert status == 400 and body["errors"]
    full = dict(MAP, segments=MAP["segments"] + [
        {"part": "top", "index": 1, "controller": 0, "zone": 0, "start": 32, "count": 8, "also": ["cooler", "strip"]}])
    status, body = light("PUT", "/api/pc-lighting/map", full)
    assert status == 200 and body["map"]["rev"] == 1
    assert _skills(env, "lighting_map_set")[-1][2]["map"]["rev"] == 1
    assert env.st.setup("pc-1")["calibrate"]["state"] == "done"


def test_probe_passes_through_only_known_keys(env):
    status, _ = light("POST", "/api/pc-lighting/probe", {"controller": 0, "zone": 1, "led": 3, "evil": True})
    assert status == 200
    assert _skills(env, "lighting_probe")[-1][2] == {"controller": 0, "zone": 1, "led": 3}


def test_setup_runs_the_step_with_a_long_timeout_and_applies_cost(env):
    env.replies["lighting_setup"] = {"ok": True, "result": {"id": "cost", "state": "done", "detail": "0.3%",
                                                           "still_in_games": False}}
    status, body = light("POST", "/api/pc-lighting/setup", {"step": "cost"})
    assert status == 200 and body["step"]["state"] == "done"
    (_, _, args, timeout), = _skills(env, "lighting_setup")
    assert args == {"step": "cost", "sensor_driver": True} and timeout >= 900
    assert env.st.setup("pc-1")["cost"]["state"] == "done"
    assert env.st.state("pc-1")["still_in_games"] is False and _skills(env, "lighting_state_set")


def test_state_event_with_old_revisions_resyncs_map_then_state(env):
    env.st.set_map("pc-1", MAP)
    env.st.update_state("pc-1", {"part": "all", "color": "#ff00ff"})
    routes.on_state_event("pc-1", {"state_rev": None, "map_version": None, "engine": "running", "controllers": []})
    names = [c[1] for c in env.calls]
    assert names == ["lighting_map_set", "lighting_state_set"]
    assert env.st.live("pc-1")["engine"] == "running"


def test_state_event_in_step_does_not_resync(env):
    env.st.set_map("pc-1", MAP)
    s = env.st.update_state("pc-1", {"part": "all", "color": "#ff00ff"})
    routes.on_state_event("pc-1", {"state_rev": s["rev"], "map_version": 1, "engine": "running", "controllers": []})
    assert env.calls == []


def test_power_off_tells_the_pc_to_stop(env, monkeypatch):
    env.st.update_state("pc-1", {"part": "all", "color": "#ff00ff"})
    routes.power_changed(False)
    assert _skills(env, "lighting_state_set")[-1][2]["enabled"] is False


def test_specs_event_is_stored_and_served(env):
    routes.on_specs_event("pc-1", {"read_at": 5.0, "board": {"product": "B760M-C"}})
    status, body = call(specs_routes, "/api/pc-specs", "GET", "/api/pc-specs?device_id=pc-1")
    assert status == 200 and body["specs"]["board"]["product"] == "B760M-C"


def test_specs_refresh_reads_from_the_pc(env):
    env.replies["pc_specs_read"] = {"ok": True, "result": {"ok": True, "specs": {"read_at": 9.0, "cpu": {"name": "i7"}}}}
    status, body = call(specs_routes, "/api/pc-specs", "POST", "/api/pc-specs/refresh", {"device_id": "pc-1"})
    assert status == 200 and body["specs"]["cpu"]["name"] == "i7"
    assert env.st.specs("pc-1")["read_at"] == 9.0
