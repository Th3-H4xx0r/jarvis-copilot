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


def test_a_queued_instruction_is_handed_over_at_the_next_stop(tmp_path, monkeypatch):
    monkeypatch.setattr(service, "_agent_config_path", lambda: str(tmp_path / "agent_config.json"))
    svc = service.Service()
    frame = {"type": "agent_instruction", "mode": "queue", "session_id": "s1", "cwd": "/w",
             "agent": "claude", "text": "also run lint"}
    svc._handle_frame(FakeWs(), frame)
    assert svc._stop_answer("claude", {"session_id": "s1"}) is None    # the switch is off by default
    svc._handle_frame(FakeWs(), {"type": "agent_config", "remote_approvals": False,
                                 "remote_instructions": True})
    svc._handle_frame(FakeWs(), frame)
    out = svc._stop_answer("claude", {"session_id": "s1"})
    assert out["decision"] == "block" and "also run lint" in out["reason"]
    assert svc._stop_answer("claude", {"session_id": "s1"}) is None     # handed over once
    svc._handle_frame(FakeWs(), dict(frame, session_id="s2"))
    assert svc._stop_answer("codex", {"session_id": "s2"}) is None      # only Claude continues this way


def test_a_type_instruction_types_into_the_terminal(tmp_path, monkeypatch):
    monkeypatch.setattr(service, "_agent_config_path", lambda: str(tmp_path / "agent_config.json"))
    from jc_client import instruction_delivery
    typed = []
    monkeypatch.setattr(instruction_delivery, "type_into",
                        lambda terminal, text, **kw: typed.append((terminal, text)) or (True, "typed"))
    svc = service.Service()
    svc._handle_frame(FakeWs(), {"type": "agent_config", "remote_approvals": False, "remote_instructions": True})
    svc._run_instruction({"type": "agent_instruction", "mode": "type", "session_id": "s1",
                          "terminal": {"iterm": "w0t1p0:ABC"}, "text": "next"}, wait=True)
    assert typed == [({"iterm": "w0t1p0:ABC"}, "next")]


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
    pv = svc._ui_request({"type": "hooks", "action": "preview", "agent": "gemini"})
    r = svc._ui_request({"type": "hooks", "action": "install", "agent": "gemini", "token": pv["token"]})
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


def test_ui_install_writes_only_what_the_preview_showed(tmp_path, monkeypatch):
    """The Mac app installs with the token of the diff it showed; if the file
    changed since, nothing is written (sweep finding)."""
    import json as _json
    monkeypatch.setenv("HOME", str(tmp_path))
    settings = tmp_path / ".claude" / "settings.json"
    settings.parent.mkdir(parents=True)
    settings.write_text(_json.dumps({"model": "opus"}))
    svc = service.Service()
    assert svc._ui_request({"type": "hooks", "action": "install"})["ok"] is False   # no token: refused
    assert "jc-hook" not in settings.read_text()
    pv = svc._ui_request({"type": "hooks", "action": "preview"})
    assert pv["ok"] is True and pv["token"]
    settings.write_text(_json.dumps({"model": "sonnet"}))        # edited after the preview
    r = svc._ui_request({"type": "hooks", "action": "install", "token": pv["token"]})
    assert r["ok"] is False and "changed" in r["error"]
    assert "jc-hook" not in settings.read_text()
    pv = svc._ui_request({"type": "hooks", "action": "preview"})
    r = svc._ui_request({"type": "hooks", "action": "install", "token": pv["token"]})
    assert r["ok"] is True and "jc-hook" in settings.read_text()
    # The other agents follow the same rule.
    gpv = svc._ui_request({"type": "hooks", "action": "preview", "agent": "gemini"})
    assert svc._ui_request({"type": "hooks", "action": "install", "agent": "gemini"})["ok"] is False
    assert svc._ui_request({"type": "hooks", "action": "install", "agent": "gemini",
                            "token": gpv["token"]})["ok"] is True


def test_ui_roster_gives_the_app_what_the_old_tray_menu_showed(monkeypatch):
    """Connected-to line, devices and wearables with their icons, for the Mac
    app's menu (the tray steps aside when the app runs)."""
    from jc_client import device_roster as dr
    svc = service.Service()
    rows = [dr.DeviceRow("Devices", "", True, header=True),
            dr.DeviceRow("Pranavs-MacBook-Pro.local", "desktop", True),
            dr.DeviceRow("Jarvis-ESP32 board", "browser", False, "last seen 10d ago"),
            dr.DeviceRow("Wearables", "", True, header=True),
            dr.DeviceRow("Colmi R12", "wearable", False, "Not connected", wearable="ring")]

    class Roster:
        def __init__(self):
            self.rows, self.error, self.asked = rows, "", 0

        def maybe_refresh(self, force=False):
            self.asked += 1

    svc._roster = Roster()
    monkeypatch.setattr(service, "_server_url", lambda: "https://jarvis.example.dev")
    r = svc._ui_request({"type": "roster"})
    assert r["ok"] is True and r["server"] == "https://jarvis.example.dev"
    assert svc._roster.asked == 1
    names = [(x["name"], x["header"]) for x in r["rows"]]
    assert names[0] == ("Devices", True) and names[3] == ("Wearables", True)
    mac = r["rows"][1]
    assert mac["symbol"] == "laptopcomputer" and mac["online"] is True
    esp = r["rows"][2]
    assert esp["symbol"] == "cpu" and esp["detail"] == "last seen 10d ago"
    ring = r["rows"][4]
    assert ring["image"].endswith("icon-ring.png")


def test_ui_tray_actions_run_what_the_old_tray_ran(monkeypatch):
    svc = service.Service()
    ran = []
    monkeypatch.setattr(service, "_spawn_client", lambda *args: ran.append(args))
    opened = []
    monkeypatch.setattr(service, "_open", lambda target: opened.append(target))
    monkeypatch.setattr(service, "_server_url", lambda: "https://jarvis.example.dev")
    assert svc._ui_request({"type": "tray", "action": "repair"})["ok"] is True
    assert svc._ui_request({"type": "tray", "action": "voice_window"})["ok"] is True
    assert svc._ui_request({"type": "tray", "action": "restart"})["ok"] is True
    assert ran == [("pair",), ("voice-popup",), ("restart",)]
    assert svc._ui_request({"type": "tray", "action": "dashboard"})["ok"] is True
    assert svc._ui_request({"type": "tray", "action": "logs"})["ok"] is True
    assert opened[0] == "https://jarvis.example.dev" and opened[1].endswith(".log")
    assert svc._ui_request({"type": "tray", "action": "rm -rf"})["ok"] is False
