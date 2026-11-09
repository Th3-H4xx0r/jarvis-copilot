"""Jarvis's Security tools are read-only and return JSON strings."""
import json

from plugins.security_advisor import tools


def test_tools_return_json_strings(monkeypatch):
    calls = []
    import tools.chrome_device_tool as cdt
    monkeypatch.setattr(cdt, "_api_request", lambda method, path, body=None, timeout=10.0:
                        calls.append((method, path)) or {"ok": True, "path": path})
    out = tools.security_status({})
    assert isinstance(out, str) and json.loads(out)["ok"] is True
    out = tools.security_events({"kind": "ssh.accepted", "limit": 500, "since": "24h"})
    assert isinstance(out, str)
    method, path = calls[-1]
    assert method == "GET" and path.startswith("/api/security/events?")
    assert "limit=100" in path and "kind=ssh.accepted" in path and "since=" in path
    assert all(m == "GET" for m, _ in calls)


def test_tool_errors_are_json(monkeypatch):
    import tools.chrome_device_tool as cdt
    monkeypatch.setattr(cdt, "_api_request", lambda *a, **k: {"_error": "webui down"})
    assert "webui down" in json.loads(tools.security_status({}))["error"]


def test_only_read_tools_exist():
    names = [t[0] for t in tools.TOOLS]
    assert names == ["security_status", "security_events"]
