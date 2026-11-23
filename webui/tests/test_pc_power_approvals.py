"""Force restart / force off for the PC power button (spec 2026-11-23): his iPhone approves with
Face ID, checked here on the server (a frozen PC can't check anything), like the car's commands."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from api.pc_power import PcPowerApprovals  # noqa: E402

PC, PC2 = "dev-pc", "dev-pc2"


class FakePower:
    def __init__(self, boards=(PC,)):
        self.boards = set(boards)
        self.forced = []

    def button_board(self, pc):
        return "dev-board" if pc in self.boards else ""

    def force(self, pc, action):
        self.forced.append((pc, action))
        return {"ok": True, "button": "power" if action == "force_off" else "reset"}


def rig(verify_ok=True, boards=(PC,)):
    power, checked, alerts = FakePower(boards), [], []

    def verify(command, nonce, ts, signature):
        checked.append((command, nonce, ts, signature))
        if not verify_ok or signature != "good":
            raise ValueError("Face ID approval didn't check out on this server.")

    ap = PcPowerApprovals(power=lambda: power, verify=verify, notify=lambda *a: alerts.append(a))
    return ap, power, checked, alerts


def test_force_creates_approval():
    ap, _, _, alerts = rig()
    out = ap.request(PC, "force_off", source="Web")
    assert out["ok"] is True and out["approval"]["command"] == "force_off"
    assert out["approval"]["title"] == "Force off PC"
    assert [a["id"] for a in ap.pending()] == [out["approval"]["id"]]
    assert alerts   # the phone hears about it


def test_force_approval_runs_after_valid_signature():
    ap, power, checked, _ = rig()
    aid = ap.request(PC, "force_restart")["approval"]["id"]
    out = ap.approve(aid, 1795000000, "good")
    assert out["ok"] is True
    assert power.forced == [(PC, "force_restart")]
    assert checked == [("force_restart", aid, 1795000000, "good")]
    assert ap.pending() == []


def test_force_approval_bad_signature_does_nothing():
    ap, power, _, _ = rig()
    aid = ap.request(PC, "force_off")["approval"]["id"]
    out = ap.approve(aid, 1795000000, "forged")
    assert out["ok"] is False and power.forced == []
    assert [a["id"] for a in ap.pending()] == [aid]   # still waiting for a real Face ID


def test_force_approval_replay_rejected():
    ap, power, _, _ = rig()
    aid = ap.request(PC, "force_off")["approval"]["id"]
    assert ap.approve(aid, 1795000000, "good")["ok"] is True
    again = ap.approve(aid, 1795000000, "good")
    assert again["ok"] is False and power.forced == [(PC, "force_off")]


def test_force_approval_binds_device():
    ap, power, _, _ = rig(boards=(PC, PC2))
    a1 = ap.request(PC, "force_off")["approval"]["id"]
    a2 = ap.request(PC2, "force_restart")["approval"]["id"]
    ap.approve(a2, 1795000000, "good")
    ap.approve(a1, 1795000000, "good")
    assert power.forced == [(PC2, "force_restart"), (PC, "force_off")]


def test_force_refused_without_board():
    ap, power, _, alerts = rig(boards=())
    out = ap.request(PC, "force_off")
    assert out == {"ok": False, "error": "No power button is linked to this PC."}
    assert ap.pending() == [] and alerts == []


def test_unknown_action_refused():
    ap, _, _, _ = rig()
    assert ap.request(PC, "explode")["ok"] is False


def test_deny_drops_it():
    ap, power, _, _ = rig()
    aid = ap.request(PC, "force_off")["approval"]["id"]
    assert ap.deny(aid) == {"ok": True}
    assert ap.pending() == [] and power.forced == []


def test_routes(monkeypatch):
    from api import pc_power
    ap, power, _, _ = rig()
    monkeypatch.setattr(pc_power, "store", lambda: ap)

    class Req:
        def __init__(self, method, sub, body=None, host_signed=False):
            self.method, self.sub, self.body, self.host_signed = method, sub, body or {}, host_signed
            self.out = None

        def reply(self, status, payload):
            self.out = (status, payload)
            return True

    r = Req("POST", "/force", {"device_id": PC, "action": "force_off"})
    pc_power.route(r)
    assert r.out[0] == 200 and r.out[1]["approval"]["command"] == "force_off"
    aid = r.out[1]["approval"]["id"]
    r = Req("GET", "/approvals")
    pc_power.route(r)
    assert r.out[0] == 200 and len(r.out[1]["approvals"]) == 1
    r = Req("POST", f"/approvals/{aid}/approve", {"ts": 1, "signature": "good"}, host_signed=True)
    pc_power.route(r)
    assert r.out[0] == 403 and power.forced == []     # Jarvis can never answer its own request
    r = Req("POST", f"/approvals/{aid}/approve", {"ts": 1, "signature": "good"})
    pc_power.route(r)
    assert r.out[0] == 200 and power.forced == [(PC, "force_off")]
