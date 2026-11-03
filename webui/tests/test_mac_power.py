"""Server side of Wake Mac, keep-awake and Mac password requests (webui/api/mac_power.py)."""
from __future__ import annotations

import json
import os
import sys

_WEBUI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_WEBUI_DIR, ".."))
for _p in (_WEBUI_DIR, _REPO_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from api.mac_power import INTENT_MAX, REQUEST_TTL, MacPowerStore  # noqa: E402

MAC = "dev-mac"


class Rig:
    def __init__(self, tmp_path, connected=()):
        self.t = 10_000.0
        self.frames, self.pushes, self.alerts, self.changes = [], [], [], []
        self.connected = set(connected)
        self.store = MacPowerStore(
            tmp_path / "mac_power.json",
            send_frame=lambda d, f: self.frames.append((d, f)) or d in self.connected,
            push=lambda token, env: self.pushes.append((token, env)) or {"ok": True},
            alert=lambda title, body, data: self.alerts.append((title, body, data)),
            changed=lambda: self.changes.append(1),
            connected=lambda: self.connected,
            clock=lambda: self.t)


def test_wake_sets_intent_and_pushes(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_token(MAC, {"token": "ab12", "env": "development"})
    out = rig.store.wake(MAC)
    assert out["ok"] is True and out["pushed"] is True
    assert rig.pushes == [("ab12", "development")]
    assert rig.store.device(MAC)["wake_requested_at"] == rig.t
    # survives a restart
    again = MacPowerStore(tmp_path / "mac_power.json", clock=lambda: rig.t)
    assert again.device(MAC)["push"] == {"token": "ab12", "env": "development"}


def test_wake_without_token_still_records_intent(tmp_path):
    rig = Rig(tmp_path)
    out = rig.store.wake(MAC)
    assert out == {"ok": True, "pushed": False}
    assert rig.store.checkin(MAC)["wake"] is True


def test_checkin_returns_and_clears_intent(tmp_path):
    rig = Rig(tmp_path)
    rig.store.wake(MAC)
    rig.t += 300
    assert rig.store.checkin(MAC) == {"wake": True, "keep_awake": False, "timer_on": True}
    assert rig.store.checkin(MAC)["wake"] is False


def test_checkin_ignores_stale_intent(tmp_path):
    rig = Rig(tmp_path)
    rig.store.wake(MAC)
    rig.t += INTENT_MAX + 1
    assert rig.store.checkin(MAC)["wake"] is False


def test_keep_awake_sends_frame(tmp_path):
    rig = Rig(tmp_path)
    rig.store.keep_awake(MAC, True)
    assert rig.frames[-1] == (MAC, {"type": "mac_power_set", "keep_awake": True})
    assert rig.store.checkin(MAC)["keep_awake"] is True
    rig.store.timer(MAC, False)
    assert rig.frames[-1] == (MAC, {"type": "mac_power_set", "timer_on": False})
    rig.store.let_sleep(MAC)
    assert rig.frames[-1] == (MAC, {"type": "mac_power_set", "let_sleep": True})
    assert rig.store.checkin(MAC) == {"wake": False, "keep_awake": False, "timer_on": False}


def test_mac_menu_change_is_stored_without_echo(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_set(MAC, {"keep_awake": True})
    assert rig.frames == []
    assert rig.store.device(MAC)["keep_awake"] is True


def test_status_marks_awake_and_clears_intent(tmp_path):
    rig = Rig(tmp_path, connected=[MAC])
    rig.store.wake(MAC)
    rig.store.on_status(MAC, {"state": "awake", "held": True, "reason": "remote", "keep_awake": False,
                              "timer_on": True, "battery": 64, "on_ac": False, "lid": "closed"})
    row = rig.store.list_payload(lambda d: "MacBook")["mac"][0]
    assert row["state"] == "awake" and row["reason"] == "remote" and row["battery"] == 64
    assert row["wake_requested_at"] is None
    assert row["name"] == "MacBook"


def test_disconnected_mac_lists_as_sleeping(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_status(MAC, {"state": "awake", "held": False})
    assert rig.store.list_payload(lambda d: "MacBook")["mac"][0]["state"] == "sleeping"


def test_password_request_listed_and_alerts_without_secret(tmp_path):
    rig = Rig(tmp_path, connected=[MAC])
    req = {"id": "r1", "kind": "sudo", "context": "sudo brew install x", "nonce": "n" * 32,
           "created": rig.t, "expires": rig.t + REQUEST_TTL}
    rig.store.on_password_request(MAC, req)
    listed = rig.store.list_payload(lambda d: "MacBook")["password_requests"]
    assert listed == [dict(req, device_id=MAC)]
    title, body, data = rig.alerts[0]
    assert data == {"kind": "mac_password", "id": "r1", "device_id": MAC}
    assert "sudo brew install x" in body
    rig.store.on_password_done(MAC, {"id": "r1", "ok": True})
    assert rig.store.list_payload(lambda d: "")["password_requests"] == []


def test_answer_relays_signature_unchanged(tmp_path):
    rig = Rig(tmp_path, connected=[MAC])
    rig.store.on_password_request(MAC, {"id": "r1", "kind": "admin", "context": "x", "nonce": "n",
                                        "created": rig.t, "expires": rig.t + 120})
    assert rig.store.answer("r1", "allow", 1700000000, "c2ln")["ok"] is True
    assert rig.frames[-1] == (MAC, {"type": "mac_password_answer", "id": "r1", "decision": "allow",
                                    "ts": 1700000000, "signature": "c2ln"})
    assert rig.store.answer("nope", "allow", 1, "s")["ok"] is False


def test_requests_expire_120s(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_password_request(MAC, {"id": "r1", "kind": "admin", "context": "x", "nonce": "n",
                                        "created": rig.t, "expires": rig.t + REQUEST_TTL})
    rig.t += REQUEST_TTL + 1
    assert rig.store.list_payload(lambda d: "")["password_requests"] == []
    assert rig.store.answer("r1", "allow", 1, "s")["ok"] is False


def test_unlock_asks_the_mac(tmp_path):
    rig = Rig(tmp_path, connected=[MAC])
    assert rig.store.unlock(MAC)["ok"] is True
    assert rig.frames[-1] == (MAC, {"type": "mac_password_unlock"})
    rig.connected.clear()
    assert rig.store.unlock(MAC)["ok"] is False


def test_state_file_never_holds_password_requests(tmp_path):
    rig = Rig(tmp_path)
    rig.store.on_token(MAC, {"token": "ab12", "env": "development"})
    rig.store.on_password_request(MAC, {"id": "r1", "kind": "sudo", "context": "x", "nonce": "secret-nonce",
                                        "created": rig.t, "expires": rig.t + 120})
    assert "secret-nonce" not in json.dumps(json.loads((tmp_path / "mac_power.json").read_text()))



def test_hello_resends_the_switches(tmp_path):
    rig = Rig(tmp_path, connected=[MAC])
    rig.store.sync(MAC)
    assert rig.frames == []                       # an unknown device (a phone) gets nothing
    rig.store.keep_awake(MAC, True)
    rig.store.timer(MAC, False)
    rig.frames.clear()
    rig.store.sync(MAC)
    assert rig.frames == [(MAC, {"type": "mac_power_set", "keep_awake": True, "timer_on": False})]


def test_keep_awake_expires_after_12h(tmp_path):
    from api.mac_power import KEEP_AWAKE_MAX
    rig = Rig(tmp_path)
    rig.store.keep_awake(MAC, True)
    rig.t += KEEP_AWAKE_MAX + 1
    assert rig.store.checkin(MAC)["keep_awake"] is False



def test_a_failed_fill_after_his_yes_tells_him_why(tmp_path):
    rig = Rig(tmp_path, connected=[MAC])
    for rid in ("r1", "r2"):
        rig.store.on_password_request(MAC, {"id": rid, "kind": "admin", "context": "x", "nonce": "n",
                                            "created": rig.t, "expires": rig.t + 120})
    rig.alerts.clear()
    rig.store.on_password_done(MAC, {"id": "r1", "ok": False,
                                     "error": "Pair your iPhone in Jarvis → Settings → Mac power first"})
    assert rig.alerts == [("Mac password not filled", "Pair your iPhone in Jarvis → Settings → Mac power first",
                           {"kind": "mac_password_failed", "id": "r1", "device_id": MAC})]
    rig.store.on_password_done(MAC, {"id": "r2", "ok": False, "error": "Not allowed"})   # his own no
    assert len(rig.alerts) == 1
