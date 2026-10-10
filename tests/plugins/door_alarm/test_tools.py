"""door_* tools: schemas, the loopback calls they make, and that disarm only asks for Face ID."""
import json

import pytest

from plugins.door_alarm import tools


@pytest.fixture
def loopback(monkeypatch):
    calls, answers = [], {}

    def fake(method, path, body=None, timeout=10.0):
        calls.append((method, path, body))
        key = (method, path.split("?")[0])
        return answers.get(key, {"ok": True})

    monkeypatch.setattr("tools.chrome_device_tool._api_request", fake)
    return calls, answers


def run(name, args):
    handler = {n: h for n, _s, h, _e in tools.TOOLS}[name]
    return json.loads(handler(args))


def test_every_schema_is_well_formed():
    names = set()
    for name, schema, handler, emoji in tools.TOOLS:
        assert schema["name"] == name and name.startswith("door_")
        assert schema["parameters"]["type"] == "object"
        assert callable(handler) and emoji
        names.add(name)
    assert names == {"door_status", "door_arm", "door_disarm", "door_silence", "door_set", "door_history",
                     "door_settings"}


def test_disarm_and_silence_only_create_an_approval(loopback):
    calls, _answers = loopback
    out = run("door_disarm", {})
    assert out["pending_approval"] is True
    assert calls == [("POST", "/api/door/approvals", {"action": "disarm"})]
    run("door_silence", {})
    assert calls[-1] == ("POST", "/api/door/approvals", {"action": "silence"})


def test_arm_passes_mode_and_bypass_and_reports_refusals(loopback):
    calls, answers = loopback
    answers[("POST", "/api/door/arm")] = {"ok": False, "error": "Front Door is open. Close it or bypass it to arm.",
                                          "open_contacts": [{"id": "dp:front", "name": "Front Door"}]}
    out = run("door_arm", {"mode": "away"})
    assert "Front Door is open" in out["error"] and out["open_contacts"][0]["id"] == "dp:front"
    run("door_arm", {"mode": "home", "bypass": ["dp:front"]})
    assert calls[-1] == ("POST", "/api/door/arm", {"mode": "home", "bypass": ["dp:front"], "source": "Jarvis"})


def test_status_summarises_without_internals(loopback):
    _calls, answers = loopback
    answers[("GET", "/api/door/state")] = {
        "setup": {"hub": True, "credentials": True, "proxy": "board1"},
        "alarm": {"state": "armed_away", "mode": "away", "seconds_left": None, "siren_on": False},
        "hub": {"name": "Wireless Doorbell", "contacts": [{"id": "dp:front", "name": "Front Door", "open": False,
                                                          "last_open": 100.0}],
                "values": {"alarm_volume": {"value": "high"}},
                "dps": [{"code": "alarm_volume", "name": "Volume", "type": "enum", "range": ["low", "high"],
                         "writable": True}],
                "link": {"local_alive": True, "cloud_alive": False}},
        "approvals": []}
    out = run("door_status", {})
    assert out["alarm"]["state"] == "armed_away"
    assert out["contacts"][0]["name"] == "Front Door"
    assert out["settings"][0] == {"code": "alarm_volume", "name": "Volume", "value": "high", "type": "enum",
                                  "choices": ["low", "high"]}
    assert out["links"] == {"esp32": True, "cloud": False}


def test_not_set_up_and_transport_errors_are_plain_errors(loopback):
    _calls, answers = loopback
    answers[("GET", "/api/door/state")] = {"_error": "connection refused"}
    assert "connection refused" in run("door_status", {})["error"]


def test_set_and_history_and_settings(loopback):
    calls, _answers = loopback
    run("door_set", {"setting": "alarm_volume", "value": "low"})
    assert calls[-1] == ("POST", "/api/door/set", {"code": "alarm_volume", "value": "low"})
    run("door_history", {"limit": 5, "contact": "dp:front"})
    assert calls[-1][0] == "GET" and calls[-1][1].startswith("/api/door/history?") and "limit=5" in calls[-1][1]
    run("door_settings", {"action": "set", "alarm": {"entry_delay": 45}})
    assert calls[-1] == ("POST", "/api/door/settings", {"alarm": {"entry_delay": 45}})
