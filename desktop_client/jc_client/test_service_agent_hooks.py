"""The service owns one hook server per process and forwards over the live bridge."""
import json
import os
import shutil
import tempfile

from jc_client import service


class FakeWs:
    def __init__(self):
        self.sent = []

    def send_text(self, text):
        self.sent.append(json.loads(text))


def test_forward_up_uses_the_live_bridge_or_drops():
    svc = service.Service()
    svc._forward_up({"type": "event", "name": "agent_hook", "data": {}})  # offline: no error
    ws = FakeWs()
    svc._ws = ws
    svc._forward_up({"type": "event", "name": "agent_hook", "data": {"kind": "event"}})
    assert ws.sent == [{"type": "event", "name": "agent_hook", "data": {"kind": "event"}}]


def test_start_agent_hooks_is_idempotent(monkeypatch):
    d = tempfile.mkdtemp(dir="/tmp", prefix="jsv")
    try:
        monkeypatch.setattr(service, "_hook_socket_path", lambda: os.path.join(d, "hook.sock"))
        svc = service.Service()
        svc.start_agent_hooks()
        first = svc._hook_server
        svc.start_agent_hooks()
        assert svc._hook_server is first
        assert os.path.exists(os.path.join(d, "hook.sock"))
        svc.stop_agent_hooks()
        assert not os.path.exists(os.path.join(d, "hook.sock"))
    finally:
        shutil.rmtree(d, ignore_errors=True)
