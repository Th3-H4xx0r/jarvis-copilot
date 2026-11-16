import json

import tools.remote_desktop_tool as t


def _fake(responses):
    return lambda method, path, body=None, timeout=10.0: responses[path]


def test_ready_pc_and_sessions_without_secrets(monkeypatch):
    monkeypatch.setattr(t, "_api_request", _fake({
        "/api/rdp/status": {"devices": [{"device_id": "pc-1", "edition": "Windows 11 Pro", "pro": True, "rdp_enabled": True,
                                         "firewall_scoped": True, "has_password": True, "idle_s": 30, "locked": False,
                                         "game": None, "username": "MicrosoftAccount\\a@b.c"}]},
        "/api/rdp/sessions": {"sessions": [{"id": "s1", "device_id": "pc-1", "client": "ios", "state": "connected",
                                            "credential": {"password": "pw"}, "enc_pub": "x"}]},
    }))
    out = json.loads(t.remote_desktop_status({}))
    assert out["ok"] and out["devices"][0]["ready"] is True and out["devices"][0]["in_use_locally"] is True
    assert out["sessions"] == [{"id": "s1", "device_id": "pc-1", "client": "ios", "state": "connected"}]
    assert "pw" not in json.dumps(out) and "a@b.c" not in json.dumps(out)


def test_home_edition_and_missing_password_explain_why(monkeypatch):
    monkeypatch.setattr(t, "_api_request", _fake({
        "/api/rdp/status": {"devices": [
            {"device_id": "pc-1", "edition": "Windows 11 Home", "pro": False},
            {"device_id": "pc-2", "edition": "Windows 11 Pro", "pro": True, "rdp_enabled": True, "firewall_scoped": True,
             "has_password": False}]},
        "/api/rdp/sessions": {"sessions": []},
    }))
    d = json.loads(t.remote_desktop_status({}))["devices"]
    assert d[0]["ready"] is False and "Windows 11 Pro" in d[0]["detail"]
    assert d[1]["ready"] is False and "password" in d[1]["detail"]


def test_off_or_unreachable(monkeypatch):
    monkeypatch.setattr(t, "_api_request", _fake({"/api/rdp/status": {"_error": "connection refused"},
                                                  "/api/rdp/sessions": {}}))
    assert json.loads(t.remote_desktop_status({}))["ok"] is False
