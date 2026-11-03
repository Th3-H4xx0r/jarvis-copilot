"""PowerService wiring (power_service.py) and AgentsLink's quiet check-ins."""
from __future__ import annotations

import threading

from jc_client.agents_link import AgentsLink
from jc_client.power_service import PowerService, sudo_context

APP, ASKPASS, SUDO, SHELL, STRANGER = 100, 200, 300, 400, 500


class FakeProcs:
    table = {APP: ("/Users/p/Applications/Jarvis.app/Contents/MacOS/Jarvis", 1, "Jarvis"),
             ASKPASS: ("/usr/bin/python3", SUDO, "python3 -I -"),
             SUDO: ("/usr/bin/sudo", SHELL, "sudo brew install --cask docker"),
             SHELL: ("/bin/zsh", 1, "/bin/zsh -c claude-tool"),
             STRANGER: ("/tmp/evil", SHELL, "evil")}

    def exe(self, pid):
        return self.table.get(pid, ("", 0, ""))[0]

    def ppid(self, pid):
        return self.table.get(pid, ("", 0, ""))[1]

    def command(self, pid):
        return self.table.get(pid, ("", 0, ""))[2]


def service():
    up, ui = [], []
    svc = PowerService(up.append, ui.append, lambda: [], lambda: None, procs=FakeProcs())
    return svc, up, ui


def app(req):
    return dict(req, _peer_pid=APP)


def _until(cond):
    for _ in range(200):
        if cond():
            return
        threading.Event().wait(0.01)


def test_fill_result_answers_the_waiting_request():
    svc, _up, ui = service()
    out = {}
    t = threading.Thread(target=lambda: out.update(reply=svc._ask_app({"type": "password_fill", "id": "r1"}, 5)))
    t.start()
    _until(lambda: ui)
    assert ui[0] == {"type": "password_fill", "id": "r1"}
    assert svc.ui_request(app({"type": "password_fill_result", "id": "r1", "ok": True, "password": "pw",
                               "extra": "dropped"})) == {"ok": True}
    t.join(2)
    assert out["reply"] == {"ok": True, "password": "pw"}
    assert svc.ui_request(app({"type": "password_fill_result", "id": "r1", "ok": True})) == {"ok": False}


def _ask_in_background(svc, ui, rid, timeout=5):
    out = {}
    t = threading.Thread(target=lambda: out.update(reply=svc._ask_app({"type": "password_fill", "id": rid}, timeout)))
    t.start()
    _until(lambda: any(m.get("id") == rid for m in ui))
    return t, out


def test_fill_result_as_the_app_sends_it_over_ui_sock():
    # JcLink.send stamps its own integer request number into "id" (the reply
    # correlation id on ui.sock), so the app names the fill in "request_id".
    svc, _up, ui = service()
    t, out = _ask_in_background(svc, ui, "r1")
    assert svc.ui_request(app({"type": "password_fill_result", "id": 57, "request_id": "r1",
                               "ok": False, "error": "Password didn't work"})) == {"ok": True}
    t.join(2)
    assert out["reply"] == {"ok": False, "error": "Password didn't work"}


def test_fill_result_from_an_older_app_with_only_its_link_id():
    # Builds before the fix lose the request id entirely: with one fill
    # waiting, that fill is the one the app answered.
    svc, _up, ui = service()
    t, out = _ask_in_background(svc, ui, "r1")
    assert svc.ui_request(app({"type": "password_fill_result", "id": 12, "ok": True})) == {"ok": True}
    t.join(2)
    assert out["reply"] == {"ok": True}


def test_fill_result_with_only_a_link_id_is_refused_when_ambiguous():
    svc, _up, ui = service()
    t1, out1 = _ask_in_background(svc, ui, "r1", timeout=0.5)
    t2, out2 = _ask_in_background(svc, ui, "r2", timeout=0.5)
    assert svc.ui_request(app({"type": "password_fill_result", "id": 12, "ok": True})) == {"ok": False}
    t1.join(2)
    t2.join(2)
    assert out1["reply"]["ok"] is False and out2["reply"]["ok"] is False


def test_menu_bar_answer_as_the_app_sends_it_over_ui_sock():
    svc, _up, _ui = service()
    seen = {}
    svc.passwords.on_local_answer = lambda rid, decision: seen.update(rid=rid, decision=decision) or True
    assert svc.ui_request(app({"type": "password_local_answer", "id": 9, "request_id": "abc",
                               "decision": "allow"})) == {"ok": True}
    assert seen == {"rid": "abc", "decision": "allow"}


def test_password_seen_twice_asks_once():
    svc, up, _ui = service()
    gate = threading.Event()
    svc.passwords._wait = lambda event, timeout: gate.wait(2) and False
    svc.ui_request(app({"type": "password_seen", "kind": "admin", "context": "Installer"}))
    _until(lambda: svc.passwords.pending())
    svc.ui_request(app({"type": "password_seen", "kind": "admin", "context": "Installer"}))
    gate.set()
    assert len([f for f in up if f.get("name") == "mac_password_request"]) == 1


def test_token_goes_up_as_event():
    svc, up, _ui = service()
    svc.ui_request(app({"type": "mac_power_token", "token": "ab12", "env": "development"}))
    assert up[-1] == {"type": "event", "name": "mac_power_token",
                      "data": {"token": "ab12", "env": "development"}}


class QuietPower:
    def __init__(self, wake):
        self.wake = wake

    def on_will_sleep(self):
        return False

    def on_did_wake(self):
        return self.wake


def test_agents_link_skips_hello_and_sleep_for_quiet_checkins():
    up = []
    link = AgentsLink(up.append, inline=True, power_thread=False, power=QuietPower(False))
    try:
        link.on_sleep()
        link.on_wake()
        assert not [f for f in up if f.get("name") in ("device_sleeping", "agent_hello")]
        link._mac_power = QuietPower(True)
        link.on_wake()
        assert [f for f in up if f.get("name") == "agent_hello"]
    finally:
        link.close()


def test_only_the_app_may_start_setup_or_answer():
    svc, _up, _ui = service()
    for kind in ("power_install", "password_local_answer", "password_fill_result", "password_seen", "approval_key"):
        out = svc.ui_request({"type": kind, "_peer_pid": STRANGER})
        assert out["ok"] is False and "Jarvis Mac app" in out["error"], kind
    assert svc.ui_request({"type": "power_install"})["ok"] is False      # no peer at all


def test_askpass_must_be_a_child_of_sudo_and_the_command_comes_from_sudo():
    svc, up, _ui = service()
    assert svc.ui_request({"type": "password_request", "command": "sudo ls", "_peer_pid": STRANGER})["ok"] is False
    seen = {}
    svc.passwords._wait = lambda event, timeout: False
    orig = svc.passwords._up

    def capture(frame):
        if frame.get("name") == "mac_password_request":
            seen["context"] = frame["data"]["context"]
        orig(frame)
    svc.passwords._up = capture
    svc.ui_request({"type": "password_request", "command": "sudo harmless", "ppid": 1, "_peer_pid": ASKPASS})
    assert seen["context"] == "sudo brew install --cask docker (started by zsh)"


def test_long_sudo_commands_say_what_was_cut():
    text = sudo_context("sudo " + "x" * 3000, "")
    assert text.endswith("more characters not shown]") and len(text) < 2100


def test_server_calls_send_a_user_agent_cloudflare_accepts(monkeypatch):
    seen = {}

    class Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return b'{"wake": false}'

    def fake_urlopen(req, timeout=0):
        seen["ua"] = req.get_header("User-agent")
        seen["url"] = req.full_url
        return Resp()
    monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)
    svc = PowerService(lambda f: None, lambda m: None, lambda: [], lambda: "http://127.0.0.1:1",
                       procs=FakeProcs())
    assert svc._checkin() == {"wake": False}
    assert seen == {"ua": "jc-client/0.1", "url": "http://127.0.0.1:1/api/coding/agents/mac/checkin"}
