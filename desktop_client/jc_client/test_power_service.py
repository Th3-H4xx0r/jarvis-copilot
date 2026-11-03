"""PowerService wiring (power_service.py) and AgentsLink's quiet check-ins."""
from __future__ import annotations

import threading

from jc_client.agents_link import AgentsLink
from jc_client.power_service import PowerService


def service():
    up, ui = [], []
    svc = PowerService(up.append, ui.append, lambda: [], lambda: None)
    return svc, up, ui


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
    assert svc.ui_request({"type": "password_fill_result", "id": "r1", "ok": True, "password": "pw",
                           "extra": "dropped"}) == {"ok": True}
    t.join(2)
    assert out["reply"] == {"ok": True, "password": "pw"}
    assert svc.ui_request({"type": "password_fill_result", "id": "r1", "ok": True}) == {"ok": False}


def test_password_seen_twice_asks_once():
    svc, up, _ui = service()
    gate = threading.Event()
    svc.passwords._wait = lambda event, timeout: gate.wait(2) and False
    svc.ui_request({"type": "password_seen", "kind": "admin", "context": "Installer"})
    _until(lambda: svc.passwords.pending())
    svc.ui_request({"type": "password_seen", "kind": "admin", "context": "Installer"})
    gate.set()
    assert len([f for f in up if f.get("name") == "mac_password_request"]) == 1


def test_token_goes_up_as_event():
    svc, up, _ui = service()
    svc.ui_request({"type": "mac_power_token", "token": "ab12", "env": "development"})
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
