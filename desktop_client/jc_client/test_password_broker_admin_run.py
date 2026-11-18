"""admin-run / pc-run (W3): his signed yes goes to the helper (elevated) or to jc-client's own runner
(unelevated) exactly once, with the exact command; no answer in 2 minutes = approval_timeout; local
answers don't count."""
from __future__ import annotations

from jc_client import pc_power
from jc_client.password_broker import PasswordBroker

CMD = "wsl --install --no-distribution  "


class Rig:
    def __init__(self, reply=None, on_request=None):
        self.t = 5000.0
        self.up, self.ui, self.asked = [], [], []
        self.reply = reply if reply is not None else {"ok": True, "exit_code": 0, "output": "done",
                                                       "truncated": False, "timed_out": False, "duration_ms": 5}
        self.on_request = on_request
        self.broker = PasswordBroker(self._up, self.ui.append, self._ask, clock=lambda: self.t, wait=self._wait)

    def _up(self, frame):
        self.up.append(frame)
        if frame["name"] == "mac_password_request" and self.on_request:
            self.on_request(self, frame["data"])

    def _ask(self, msg, timeout):
        self.asked.append((msg, timeout))
        return dict(self.reply)

    def _wait(self, event, timeout):
        if not event.is_set():
            self.t += timeout
        return event.is_set()

    def sent(self):
        return [f["data"] for f in self.up if f["name"] == "mac_password_request"]


def yes(rig, req):
    rig.broker.on_answer(req["id"], "allow", 1700000000, "c2ln")


def test_broker_admin_run_relays_signed_yes_to_helper_once():
    rig = Rig(on_request=yes)
    out = rig.broker.request("admin-run", CMD, why="Enable WSL2", run_timeout=900)
    req = rig.sent()[0]
    assert req["context"] == CMD and req["why"] == "Enable WSL2" and req["kind"] == "admin-run"
    assert len(rig.asked) == 1
    msg, timeout = rig.asked[0]
    assert msg == {"type": "admin_run", "id": req["id"], "command": CMD, "nonce": req["nonce"],
                   "proof": {"ts": 1700000000, "signature": "c2ln"}, "timeout_s": 900} and timeout == 915
    assert out == {"ok": True, "status": "ran", "exit_code": 0, "output": "done", "truncated": False,
                   "timed_out": False, "duration_ms": 5, "error": ""}


def test_broker_pc_run_runs_unelevated_and_maps_output():
    rig = Rig(on_request=yes, reply={"ok": True, "exit_code": 0, "stdout": "removed", "stderr": "warn",
                                     "truncated": False, "timed_out": False, "duration_ms": 7})
    out = rig.broker.request("pc-run", "winget remove x", why="clean up", run_timeout=300)
    assert rig.asked[0][0]["type"] == "pc_run" and out["status"] == "ran" and out["output"] == "removed\nwarn"


def test_broker_admin_run_helper_failure_is_failed():
    rig = Rig(on_request=yes, reply={"ok": False, "error": "bad signature"})
    out = rig.broker.request("admin-run", CMD, why="x", run_timeout=600)
    assert out["ok"] is False and out["status"] == "failed" and out["error"] == "bad signature"


def test_broker_admin_run_timeout_is_approval_timeout():
    rig = Rig()
    out = rig.broker.request("admin-run", CMD, why="x", run_timeout=600)
    assert out["ok"] is False and out["status"] == "approval_timeout" and rig.asked == []


def test_broker_admin_run_deny_is_denied():
    rig = Rig(on_request=lambda r, req: r.broker.on_answer(req["id"], "deny", 1, "s"))
    out = rig.broker.request("admin-run", CMD, why="x", run_timeout=600)
    assert out["status"] == "denied" and rig.asked == []


def test_admin_run_ignores_local_answers():
    seen = {}

    def local_then_timeout(rig, req):
        seen["accepted"] = rig.broker.on_local_answer(req["id"], "allow")
    rig = Rig(on_request=local_then_timeout)
    out = rig.broker.request("admin-run", CMD, why="x", run_timeout=600)
    assert seen["accepted"] is False and out["status"] == "approval_timeout" and rig.asked == []


def test_admin_run_context_is_never_truncated():
    rig = Rig(on_request=yes)
    rig.broker.request("admin-run", "y" * 2400, why="x", run_timeout=600)
    assert rig.sent()[0]["context"] == "y" * 2400 and rig.asked[0][0]["command"] == "y" * 2400


def test_pc_power_routes_admin_run_to_helper(monkeypatch):
    from jc_client import helper_pipe
    calls, ui = [], []
    monkeypatch.setattr(helper_pipe, "admin_run", lambda *a, **k: calls.append((a, k)) or {"ok": True, "exit_code": 0})
    power = pc_power.PcPower(lambda f: True, ui_broadcast=ui.append, set_state=lambda f: 1, lock=lambda: None,
                             suspend=lambda: None, probe=lambda: (None, None), battery=lambda: (None, None),
                             lan_ip=lambda: "")
    out = power._ask_app({"type": "admin_run", "id": "r1", "command": CMD, "nonce": "n" * 32,
                          "proof": {"ts": 1700000000, "signature": "c2ln"}, "timeout_s": 600}, 615)
    assert out == {"ok": True, "exit_code": 0} and ui == []
    assert calls[0][0] == (CMD, "n" * 32, 1700000000, "c2ln", 600)


def test_pc_power_runs_pc_run_itself(monkeypatch):
    from jc_client.skills import pc_it
    ran = []
    monkeypatch.setattr(pc_it, "run_powershell", lambda c, t: ran.append((c, t)) or {"ok": True, "exit_code": 0,
                                                                                     "stdout": "", "stderr": ""})
    power = pc_power.PcPower(lambda f: True, ui_broadcast=lambda m: None, set_state=lambda f: 1, lock=lambda: None,
                             suspend=lambda: None, probe=lambda: (None, None), battery=lambda: (None, None),
                             lan_ip=lambda: "")
    power._ask_app({"type": "pc_run", "id": "r1", "command": "winget remove x", "nonce": "n",
                    "proof": {"ts": 1, "signature": "s"}, "timeout_s": 300}, 315)
    assert ran == [("winget remove x", 300)]
