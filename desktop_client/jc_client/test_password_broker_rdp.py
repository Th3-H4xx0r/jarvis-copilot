"""Remote Desktop credential release on the PC (plan 2026-11-15-remote-desktop, Task 2): the server's
rdp_credential_request becomes a Face ID request whose signed context is exactly the session's,
his yes goes to the Jarvis app as one password_release, and the app's rdp_credential goes back up
for that session only."""
from __future__ import annotations

import json

from jc_client.password_broker import PasswordBroker
from jc_client.pc_power import PcPower

CTX = json.dumps({"session": "s-1", "client": "web", "enc_pub": None, "device": "pranav-computer"},
                 sort_keys=True, separators=(",", ":"))


class Rig:
    def __init__(self, app_reply=None, on_request=None):
        self.t = 5000.0
        self.up, self.ui, self.asked = [], [], []
        self.app_reply = app_reply if app_reply is not None else {"ok": True, "credential": {"password": "pw"}}
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
        if not event.is_set():
            self.t += timeout
        return event.is_set()


def answers(decision="allow", ts=123, signature="sig", twice=False):
    def go(rig, req):
        rig.broker.on_answer(req["id"], decision, ts, signature)
        if twice:
            rig.broker.on_answer(req["id"], decision, ts, signature)
    return go


def test_rdp_request_context_is_signed_verbatim():
    rig = Rig(on_request=answers(ts=1700000000, signature="c2ln"))
    out = rig.broker.request("rdp", CTX)
    req = [f for f in rig.up if f["name"] == "mac_password_request"][0]["data"]
    assert req["kind"] == "rdp" and req["context"] == CTX          # exactly what his signature covers
    assert rig.asked == [{"type": "password_release", "id": req["id"], "kind": "rdp", "context": CTX,
                          "nonce": req["nonce"], "proof": {"ts": 1700000000, "signature": "c2ln"}}]
    assert out == {"ok": True, "credential": {"password": "pw"}}
    # the password never goes up the server link from the broker, nor to the UI broadcast
    assert "pw" not in json.dumps([f for f in rig.up if f["name"] != "rdp_credential"]) + json.dumps(rig.ui)


def test_rdp_one_release_per_request():
    rig = Rig(on_request=answers(twice=True))
    rig.broker.request("rdp", CTX)
    assert len(rig.asked) == 1                         # a repeated yes doesn't release twice
    denied = Rig(on_request=answers(decision="deny"))
    assert denied.broker.request("rdp", CTX) == {"ok": False, "error": "Not allowed"}
    assert denied.asked == []                          # no yes, nothing asked of the app
    silent = Rig()
    assert silent.broker.request("rdp", CTX)["ok"] is False and silent.asked == []
    refused = Rig(app_reply={"ok": False, "error": "No saved password"}, on_request=answers())
    assert refused.broker.request("rdp", CTX) == {"ok": False, "error": "No saved password"}


class PcRig:
    """PcPower with its broker's Face ID answered at once and the app's reply scripted."""

    def __init__(self, app_frame):
        self.up, self.ui = [], []
        self.app_frame = app_frame
        self.pc = PcPower(self.up.append, probe=lambda: ({"capable": False}, ""), battery=lambda: (None, None),
                          lan_ip=lambda: "", ui_broadcast=self._ui, is_app=lambda pid: pid == 4242,
                          spawn=lambda fn, *a: fn(*a))

    def _ui(self, msg):
        self.ui.append(msg)
        if msg.get("type") == "mac_password_request" or msg.get("type") == "password_request":
            self.pc.passwords.on_answer(msg["id"], "allow", 1, "sig")
        if msg.get("type") == "password_release" and self.app_frame is not None:
            self.pc.ui_request({**self.app_frame, "_peer_pid": 4242, "request_id": msg["id"]})


def test_pc_forwards_request_and_relays_credential_up():
    rig = PcRig({"type": "rdp_credential", "session_id": "s-1", "ok": True, "credential": {"password": "pw"}})
    rig.pc.handle_frame({"type": "rdp_credential_request", "session_id": "s-1", "client": "web", "context": CTX})
    sent = [f for f in rig.up if f.get("name") == "rdp_credential"]
    assert sent == [{"type": "event", "name": "rdp_credential",
                     "data": {"session_id": "s-1", "ok": True, "credential": {"password": "pw"}}}]


def test_pc_refuses_a_context_for_another_session():
    rig = PcRig({"type": "rdp_credential", "session_id": "s-1", "ok": True, "credential": {"password": "pw"}})
    rig.pc.handle_frame({"type": "rdp_credential_request", "session_id": "s-OTHER", "client": "web", "context": CTX})
    sent = [f for f in rig.up if f.get("name") == "rdp_credential"]
    assert sent[-1]["data"]["ok"] is False and "credential" not in sent[-1]["data"]
    assert not any(m.get("type") == "password_release" for m in rig.ui)


def test_pc_only_takes_a_credential_from_the_jarvis_app():
    rig = PcRig(None)
    assert rig.pc.ui_request({"type": "rdp_credential", "session_id": "s-1", "ok": True,
                              "credential": {"password": "pw"}, "_peer_pid": 999})["ok"] is False
