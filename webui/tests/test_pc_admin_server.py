"""PC admin actions on the server (contract C6): the PC asks, his iPhone approves with Face ID
(checked here, like the car), and only then does the PC hear "approved"."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from api import pc_admin  # noqa: E402
from api.pc_admin import PcAdminStore  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def _store(verify_ok=True):
    sent, alerts, clock, checked = [], [], Clock(), []

    def verify(command, nonce, ts, signature):
        checked.append((command, nonce, ts, signature))
        if not verify_ok:
            raise ValueError("Face ID approval didn't check out on this server.")

    st = PcAdminStore(send_frame=lambda did, f: sent.append((did, f)) or True,
                      alert=lambda title, body, data: alerts.append((title, body, data)),
                      verify=verify, clock=clock, name_of=lambda did: "Pranav-Desktop")
    return st, sent, alerts, clock, checked


REQ = {"request_id": "a" * 32, "command": "winget install Spotify", "why": "install Spotify"}


def test_request_alerts_phone_and_lists():
    st, _, alerts, _, _ = _store()
    st.on_request("pc-1", REQ)
    assert alerts and alerts[0][0] == "Run as admin on Pranav-Desktop"
    assert alerts[0][2]["kind"] == "pc_admin" and alerts[0][2]["id"] == "a" * 32
    [item] = st.pending()
    assert item["command"] == "winget install Spotify" and item["device_id"] == "pc-1"
    assert item["device_name"] == "Pranav-Desktop" and item["why"] == "install Spotify"


def test_allow_needs_valid_signature():
    st, sent, _, _, _ = _store(verify_ok=False)
    st.on_request("pc-1", REQ)
    out = st.answer("a" * 32, "allow", 1000, "sig")
    assert out["ok"] is False and "check out" in out["error"]
    assert sent == []
    assert st.pending()   # still waiting for a good answer


def test_allow_sends_approved_decision():
    st, sent, _, _, checked = _store()
    st.on_request("pc-1", REQ)
    assert st.answer("a" * 32, "allow", 1000, "sig") == {"ok": True}
    assert checked == [(pc_admin.SIGNED_COMMAND, "a" * 32, 1000, "sig")]
    assert sent == [("pc-1", {"type": "pc_admin_decision", "request_id": "a" * 32, "approved": True})]
    assert st.pending() == []


def test_deny_sends_denied_decision_without_face_id():
    st, sent, _, _, checked = _store()
    st.on_request("pc-1", REQ)
    assert st.answer("a" * 32, "deny", None, None) == {"ok": True}
    assert checked == []
    assert sent == [("pc-1", {"type": "pc_admin_decision", "request_id": "a" * 32, "approved": False})]


def test_late_approval_after_timeout_is_ignored():
    st, sent, _, clock, _ = _store()
    st.on_request("pc-1", REQ)
    clock.t += pc_admin.REQUEST_TTL + 1
    assert st.answer("a" * 32, "allow", 1000, "sig") == {"ok": False, "error": "expired"}
    assert sent == [] and st.pending() == []


def test_bad_request_ignored():
    st, _, alerts, _, _ = _store()
    st.on_request("pc-1", {"request_id": "", "command": "x"})
    st.on_request("pc-1", {"request_id": "b" * 32, "command": "  "})
    assert st.pending() == [] and alerts == []


def test_unknown_decision_rejected():
    st, sent, _, _, _ = _store()
    st.on_request("pc-1", REQ)
    assert st.answer("a" * 32, "maybe", None, None)["ok"] is False
    assert sent == []


def test_approvals_in_face_id_card_shape():
    st, _, _, clock, _ = _store()
    st.on_request("pc-1", REQ)
    clock.t += 10
    [a] = st.approvals()
    assert a["id"] == "a" * 32 and a["command"] == pc_admin.SIGNED_COMMAND
    assert a["title"] == "Run as admin on Pranav-Desktop" and a["age_s"] == 10
    assert a["expires_in_s"] == int(pc_admin.REQUEST_TTL) - 10
    assert a["detail"] == "install Spotify\nwinget install Spotify"


def _req(method, sub, body=None, host=False):
    from types import SimpleNamespace
    box = {}
    req = SimpleNamespace(method=method, sub=sub, body=body or {}, host_signed=host)
    req.reply = lambda status, payload: box.update(status=status, body=payload) or True
    return req, box


def test_route_lists_approves_and_refuses_jarvis(monkeypatch):
    st, sent, _, _, _ = _store()
    st.on_request("pc-1", REQ)
    monkeypatch.setattr(pc_admin, "store", lambda: st)
    req, box = _req("GET", "/approvals")
    pc_admin.route(req)
    assert box["status"] == 200 and box["body"]["approvals"][0]["id"] == "a" * 32
    req, box = _req("POST", f"/approvals/{'a' * 32}/approve", {"ts": 1000, "signature": "s"}, host=True)
    pc_admin.route(req)
    assert box["status"] == 403 and sent == []          # Jarvis can't approve its own request
    req, box = _req("POST", f"/approvals/{'a' * 32}/approve", {})
    pc_admin.route(req)
    assert box["status"] == 400
    req, box = _req("POST", f"/approvals/{'a' * 32}/approve", {"ts": 1000, "signature": "s"})
    pc_admin.route(req)
    assert box["status"] == 200 and sent[-1][1]["approved"] is True
