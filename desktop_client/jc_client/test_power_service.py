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
