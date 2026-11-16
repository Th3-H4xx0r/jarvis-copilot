"""PC Stats over HTTP: samples → live/summary, offline, the live flag, dashboards, energy."""
from __future__ import annotations

import io
import sys
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.pc_stats_routes as routes  # noqa: E402
from api.pc_stats_store import PcStatsStore  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 1_800_000_000.0

    def __call__(self):
        return self.t


@pytest.fixture()
def env(tmp_path, monkeypatch):
    clock = Clock()
    st = PcStatsStore(tmp_path / "pc", clock=clock)
    monkeypatch.setattr(routes, "store", lambda: st)
    monkeypatch.setattr(routes, "_clock", clock)
    monkeypatch.setattr(routes, "_name", lambda d: "pranav-computer")
    monkeypatch.setattr(routes, "_settings", lambda: {"price": 0.2, "currency": "USD", "history": True})
    routes._watched.clear()
    return SimpleNamespace(st=st, clock=clock)


def call(method, path, body=None, caller="pc-1"):
    box = {}
    parsed = urlparse(path)
    req = SimpleNamespace(method=method, path=parsed.path, parsed=parsed, body=body, host_signed=False,
                          prefix="/api/pc-stats", handler=SimpleNamespace(rfile=io.BytesIO(b""), headers={}),
                          sub=parsed.path[len("/api/pc-stats"):], device={"id": caller} if caller else None,
                          query=parse_qs(parsed.query))
    req.reply = lambda status, payload: box.update(status=status, body=payload) or True
    assert routes.route(req) is not False
    return box["status"], box["body"]


def _post(env, **r):
    return call("POST", "/api/pc-stats/samples",
                {"device_id": "pc-1", "samples": [{"t": env.clock.t, "r": r, "game": None}], "estimated": ["power.total"]})


def test_samples_then_live_and_summary(env):
    status, body = _post(env, **{"cpu.load": 38, "gpu.load": 96, "cpu.temp": 72, "gpu.temp": 67, "power.total": 462})
    assert status == 200 and body == {"ok": True, "live": False}
    _, live = call("GET", "/api/pc-stats/live?device_id=pc-1", caller="iphone")
    assert live["online"] is True and live["sample"]["r"]["gpu.load"] == 96 and live["estimated"] == ["power.total"]
    assert live["name"] == "pranav-computer"
    _, summary = call("GET", "/api/pc-stats/summary", caller="iphone")   # defaults to the reporting PC
    assert summary == {"device_id": "pc-1", "online": True, "at": env.clock.t, "cpu": 38.0, "gpu": 96.0,
                       "cpu_temp": 72.0, "gpu_temp": 67.0, "hottest": 72.0, "watts": 462.0}


def test_live_offline_returns_last_seen(env):
    _post(env, **{"cpu.load": 10})
    seen = env.clock.t
    env.clock.t += 3600
    _, live = call("GET", "/api/pc-stats/live?device_id=pc-1", caller="iphone")
    assert live["online"] is False and live["at"] == seen and live["sample"]["r"]["cpu.load"] == 10
    _, nothing = call("GET", "/api/pc-stats/live?device_id=never", caller="iphone")
    assert nothing["online"] is False and nothing["sample"] is None


def test_live_flag_true_only_while_watched(env):
    call("GET", "/api/pc-stats/live?device_id=pc-1", caller="iphone")
    assert _post(env, **{"cpu.load": 1})[1]["live"] is True
    env.clock.t += 16
    assert _post(env, **{"cpu.load": 1})[1]["live"] is False


def test_dashboards_put_conflict_and_400(env):
    _, body = call("GET", "/api/pc-stats/dashboards")
    d = body["dashboards"][0]
    status, saved = call("PUT", f"/api/pc-stats/dashboards/{d['id']}", {"dashboard": {**d, "name": "Main"}, "rev": d["rev"]})
    assert status == 200 and saved["dashboard"]["rev"] == d["rev"] + 1
    status, body = call("PUT", f"/api/pc-stats/dashboards/{d['id']}", {"dashboard": {**d, "name": "Old"}, "rev": d["rev"]})
    assert status == 409 and body["dashboard"]["name"] == "Main"
    status, body = call("PUT", "/api/pc-stats/dashboards/new", {"dashboard": {"name": "N", "widgets": [{"id": "a", "kind": "pie"}]}})
    assert status == 400 and body["errors"]


def test_catalog_and_energy_shape(env):
    _, cat = call("GET", "/api/pc-stats/catalog")
    assert "gpu.temp" in cat["readings"] and cat["columns"] == 12 and "hero" in cat["widget_kinds"]
    _, energy = call("GET", "/api/pc-stats/energy?device_id=pc-1&period=week")
    assert energy["currency"] == "USD" and len(energy["buckets"]) == 12
