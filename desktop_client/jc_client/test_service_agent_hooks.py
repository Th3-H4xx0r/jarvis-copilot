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
        monkeypatch.setattr(service, "_ui_socket_path", lambda: os.path.join(d, "ui.sock"))
        from jc_client import plan_usage
        polls = []
        monkeypatch.setattr(plan_usage.CodexPoller, "start", lambda self: polls.append(self))
        svc = service.Service()
        svc.start_agent_hooks()
        assert len(polls) == 1
        first = svc._hook_server
        svc.start_agent_hooks()
        assert svc._hook_server is first
        assert os.path.exists(os.path.join(d, "hook.sock"))
        svc.stop_agent_hooks()
        assert not os.path.exists(os.path.join(d, "hook.sock"))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_agent_config_frame_sets_the_gate_and_is_remembered(tmp_path, monkeypatch):
    monkeypatch.setattr(service, "_agent_config_path", lambda: str(tmp_path / "agent_config.json"))
    svc = service.Service()
    assert svc._approvals_gate() is False
    svc._handle_frame(FakeWs(), {"type": "agent_config", "remote_approvals": True})
    assert svc._approvals_gate() is True
    assert service.Service()._approvals_gate() is True  # a fresh process reads it back


def test_agent_decision_frame_reaches_the_arbiter():
    svc = service.Service()
    calls = []

    class Arb:
        def decide(self, fp, decision, message=None, answers=None):
            calls.append((fp, decision, message, answers))
            return True

    svc._arbiter = Arb()
    svc._handle_frame(FakeWs(), {"type": "agent_decision", "fingerprint": "f1",
                                 "decision": "deny", "message": "nope"})
    assert calls == [("f1", "deny", "nope", None)]


def test_hello_asks_the_server_for_the_agent_config():
    svc = service.Service()
    ws = FakeWs()
    svc._ws = ws
    svc._agent_hello()
    assert ws.sent == [{"type": "event", "name": "agent_hello", "data": {"v": 1}}]


def test_instruction_frame_runs_only_when_allowed(tmp_path, monkeypatch):
    monkeypatch.setattr(service, "_agent_config_path", lambda: str(tmp_path / "agent_config.json"))
    svc = service.Service()
    runs = []

    class Runner:
        def run(self, sid, cwd, text):
            runs.append((sid, text))
            return True, "started"

    svc._instructions = Runner()
    frame = {"type": "agent_instruction", "session_id": "s1", "cwd": "/w", "text": "go on"}
    svc._handle_frame(FakeWs(), frame)
    assert runs == []  # the switch is off by default
    svc._handle_frame(FakeWs(), {"type": "agent_config", "remote_approvals": False,
                                 "remote_instructions": True})
    svc._handle_frame(FakeWs(), frame)
    assert runs == [("s1", "go on")]


class FakeUi:
    def __init__(self):
        self.sent = []

    def broadcast(self, msg):
        self.sent.append(msg)


def test_ui_decide_goes_to_the_arbiter():
    svc = service.Service()
    calls = []

    class Arb:
        def decide(self, fp, decision, message=None, answers=None):
            calls.append((fp, decision, answers))
            return fp == "good"

        def pending(self):
            return []

    svc._arbiter = Arb()
    assert svc._ui_request({"type": "decide", "fingerprint": "good", "decision": "allow"}) == {"ok": True}
    assert svc._ui_request({"type": "decide", "fingerprint": "stale", "decision": "allow"}) == {"ok": False}
    assert calls[0] == ("good", "allow", None)


def test_ui_subscribe_forwards_the_union_to_the_server():
    svc = service.Service()
    ws = FakeWs()
    svc._ws = ws
    svc._ui_request({"type": "subscribe", "topics": {"services": 0, "portfolio": 5}})
    assert ws.sent[-1] == {"type": "subscribe", "topics": {"services": 0, "portfolio": 5}}


def test_server_topic_frames_reach_the_app():
    svc = service.Service()
    svc._ui = FakeUi()
    svc._handle_frame(FakeWs(), {"type": "topic", "topic": "services", "data": {"services": []}})
    assert svc._ui.sent == [{"type": "topic", "topic": "services", "data": {"services": []}}]


def test_config_change_is_told_to_the_app(tmp_path, monkeypatch):
    monkeypatch.setattr(service, "_agent_config_path", lambda: str(tmp_path / "c.json"))
    svc = service.Service()
    svc._ui = FakeUi()
    svc._handle_frame(FakeWs(), {"type": "agent_config", "remote_approvals": True,
                                 "remote_instructions": False})
    assert svc._ui.sent == [{"type": "config", "approvals": True, "instructions": False}]


def test_unknown_ui_request_is_refused():
    svc = service.Service()
    assert svc._ui_request({"type": "frobnicate"})["ok"] is False


def test_ui_hooks_handles_the_other_agents(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    svc = service.Service()
    r = svc._ui_request({"type": "hooks", "action": "install", "agent": "gemini"})
    assert r["ok"] is True and r["status"]["installed"] is True
    assert (tmp_path / ".gemini" / "settings.json").exists()
    assert not (tmp_path / ".claude" / "settings.json").exists()
    allr = svc._ui_request({"type": "hooks", "action": "status", "agent": "all"})
    assert allr["agents"]["gemini"]["installed"] is True
    assert allr["agents"]["codex"]["installed"] is False
    assert "claude" in allr["agents"]
    r = svc._ui_request({"type": "hooks", "action": "uninstall", "agent": "gemini"})
    assert r["ok"] is True and r["changed"] is True
    assert svc._ui_request({"type": "hooks", "action": "install", "agent": "nope"})["ok"] is False
