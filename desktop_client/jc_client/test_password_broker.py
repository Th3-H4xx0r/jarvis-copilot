"""Password requests: ask Pranav, route his signed yes to the Mac app, never leak (password_broker.py)."""
from __future__ import annotations

import json

from jc_client.password_broker import TIMEOUT, PasswordBroker


class Rig:
    def __init__(self, app_reply=None, on_request=None):
        self.t = 5000.0
        self.up, self.ui, self.asked = [], [], []
        self.app_reply = app_reply if app_reply is not None else {"ok": True, "password": "hunter2"}
        self.on_request = on_request
        self.broker = PasswordBroker(self._up, self.ui.append, self._ask_app,
                                     clock=lambda: self.t, wait=self._wait)

    def _up(self, frame):
        self.up.append(frame)
        if frame["name"] == "mac_password_request" and self.on_request:
            self.on_request(self, frame["data"])

    def _ask_app(self, msg, timeout):
        self.asked.append(msg)
        return dict(self.app_reply)

    def _wait(self, event, timeout):
        if not event.is_set():          # nobody answered: time passes, it expires
            self.t += timeout
        return event.is_set()

    def done(self):
        return [f for f in self.up if f["name"] == "mac_password_done"][-1]["data"]

    def sent(self):
        return [f for f in self.up if f["name"] == "mac_password_request"]


def answers(decision="allow", ts=123, signature="sig"):
    return lambda rig, req: rig.broker.on_answer(req["id"], decision, ts, signature)


def test_request_sends_no_password_up():
    rig = Rig(on_request=answers())
    assert rig.broker.request("sudo", "sudo brew install x", ppid=42) == {"ok": True, "password": "hunter2"}
    assert "hunter2" not in json.dumps(rig.up) + json.dumps(rig.ui)
    req = rig.sent()[0]["data"]
    assert set(req) == {"id", "kind", "context", "nonce", "created", "expires"}
    assert req["expires"] - req["created"] == TIMEOUT == 120.0
    assert len(req["nonce"]) == 32
    assert rig.ui[0]["type"] == "password_request"


def test_allow_routes_proof_to_app():
    rig = Rig(on_request=answers(ts=1700000000, signature="c2ln"))
    rig.broker.request("sudo", "sudo ls", ppid=7)
    req = rig.sent()[0]["data"]
    assert rig.asked[0] == {"type": "password_fill", "id": req["id"], "kind": "sudo", "nonce": req["nonce"],
                            "proof": {"ts": 1700000000, "signature": "c2ln"}}


def test_timeout_120s_denies():
    rig = Rig()
    assert rig.broker.request("sudo", "sudo ls", ppid=1) == {"ok": False, "error": "No answer in 2 minutes"}
    assert rig.asked == []
    assert rig.done()["ok"] is False


def test_deny_returns_not_ok():
    rig = Rig(on_request=answers("deny"))
    assert rig.broker.request("sudo", "sudo ls", ppid=1)["ok"] is False
    assert rig.asked == []
    assert rig.done()["error"] == "Not allowed"


def test_failed_fill_reports_and_never_retries():
    rig = Rig(app_reply={"ok": False, "error": "Password didn't work"}, on_request=answers())
    assert rig.broker.request("admin", "Installer")["ok"] is False
    assert rig.done() == {"id": rig.done()["id"], "ok": False, "error": "Password didn't work"}
    assert len(rig.asked) == 1


def test_sudo_asking_again_after_a_password_is_refused():
    rig = Rig(on_request=answers())
    assert rig.broker.request("sudo", "sudo ls", ppid=99)["ok"] is True
    # sudo calls askpass again only when the password was wrong: don't ask him again
    out = rig.broker.request("sudo", "sudo ls", ppid=99)
    assert out["ok"] is False and "didn't work" in out["error"]
    assert len(rig.sent()) == 1


def test_second_answer_ignored():
    seen = {}

    def on_request(rig, req):
        seen["first"] = rig.broker.on_answer(req["id"], "allow", 1, "s")
        seen["second"] = rig.broker.on_answer(req["id"], "deny", 2, "t")
        seen["local"] = rig.broker.on_local_answer(req["id"], "deny")
    rig = Rig(on_request=on_request)
    assert rig.broker.request("keychain", "Keychain")["ok"] is True
    assert seen == {"first": True, "second": False, "local": False}


def test_unknown_id_ignored():
    rig = Rig()
    assert rig.broker.on_answer("nope", "allow", 1, "s") is False


def test_local_answer_uses_local_proof():
    rig = Rig(on_request=lambda rig, req: rig.broker.on_local_answer(req["id"], "allow"))
    rig.broker.request("unlock", "Unlock Mac")
    assert rig.asked[0]["proof"] == {"local": True}


def test_pending_counts_for_hold():
    seen = {}

    def on_request(rig, req):
        seen["pending"] = [p["id"] for p in rig.broker.pending()]
        rig.broker.on_answer(req["id"], "deny", None, None)
    rig = Rig(on_request=on_request)
    rig.broker.request("admin", "Installer")
    assert len(seen["pending"]) == 1
    assert rig.broker.pending() == []
