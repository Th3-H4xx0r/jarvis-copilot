from __future__ import annotations
import http.client
import importlib
import json
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))


class FakeHandler:
    def __init__(self):
        self.status = None
        self.headers = http.client.HTTPMessage()
        self._sent = []
        self.wbuf = []
    def send_response(self, c): self.status = c
    def send_header(self, k, v): self._sent.append((k, v))
    def end_headers(self): pass
    @property
    def wfile(self):
        h = self
        class W:
            def write(self, b): h.wbuf.append(b)
        return W()


def _routes():
    from api import routes
    importlib.reload(routes)
    return routes


def _json(h):
    return json.loads(b"".join(h.wbuf).decode("utf-8"))


def _stub_send(monkeypatch, result):
    """Inject a fake tools.send_message_tool so the handler's import picks it up."""
    sent = {}
    fake = types.ModuleType("tools.send_message_tool")
    def smt(args, **kw):
        sent.update(args)
        return json.dumps(result)
    fake.send_message_tool = smt
    fake._get_cron_auto_delivery_target = lambda: None
    monkeypatch.setitem(sys.modules, "tools.send_message_tool", fake)
    return sent


def test_notify_sends_to_target(monkeypatch):
    routes = _routes()
    sent = _stub_send(monkeypatch, {"success": True})
    h = FakeHandler()
    routes._handle_notify(h, {"text": "hi there", "target": "telegram:42"})
    assert _json(h)["ok"] is True
    assert sent["action"] == "send" and sent["target"] == "telegram:42" and sent["message"] == "hi there"


def test_notify_requires_text(monkeypatch):
    routes = _routes()
    _stub_send(monkeypatch, {"success": True})
    h = FakeHandler()
    routes._handle_notify(h, {"target": "telegram:42"})
    assert h.status == 400


def test_notify_no_target_returns_not_ok(monkeypatch):
    routes = _routes()
    _stub_send(monkeypatch, {"success": True})
    h = FakeHandler()
    routes._handle_notify(h, {"text": "hi"})  # no target, no cron fallback
    body = _json(h)
    assert body["ok"] is False and "target" in body["error"]


def test_notify_surfaces_send_failure(monkeypatch):
    routes = _routes()
    _stub_send(monkeypatch, {"error": "platform not configured"})
    h = FakeHandler()
    routes._handle_notify(h, {"text": "hi", "target": "telegram:42"})
    body = _json(h)
    assert body["ok"] is False and "not configured" in body["error"]


def test_notify_list(monkeypatch):
    routes = _routes()
    fake = types.ModuleType("gateway.channel_directory")
    fake.format_directory_for_display = lambda: "telegram: home (123)"
    monkeypatch.setitem(sys.modules, "gateway.channel_directory", fake)
    h = FakeHandler()
    routes._handle_notify_list(h)
    assert "telegram" in _json(h)["targets"]
