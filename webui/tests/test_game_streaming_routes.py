"""Game streaming routes: status, start (awake/pending), pair, event."""
from __future__ import annotations

import pytest

from api import game_streaming_routes as R
from api.game_streaming_store import GameStreamingStore


class Req:
    def __init__(self, method, sub, body=None, query=None):
        self.method = method
        self.sub = sub
        self.body = body or {}
        self.query = query or {}
        self.replied = None

    def reply(self, code, data):
        self.replied = (code, data)
        return True


@pytest.fixture
def wired(tmp_path, monkeypatch):
    st = GameStreamingStore(tmp_path)
    calls = []
    monkeypatch.setattr(R, "store", lambda: st)
    monkeypatch.setattr(R, "_pc_id", lambda: "pc")
    monkeypatch.setattr(R, "_sunshine_conn", lambda: {"host": "gpc", "port": 47990, "user": "a", "password": "b"})
    monkeypatch.setattr(R, "_targets", lambda: [{"name": "Mac", "kind": "mac", "host": "gpc"}])
    monkeypatch.setattr(R, "_current_game", lambda: None)
    monkeypatch.setattr(R, "_wake_pc", lambda: calls.append(("wake",)) or True)
    monkeypatch.setattr(R, "_device_for_kind", lambda kind: "mac-dev")

    def fake_invoke(did, skill, args, timeout=20):
        calls.append((did, skill, args))
        if skill == "game_stream_status":
            return {"ok": True, "data": {"reachable": True, "paired": [{"name": "Mac", "uuid": "u1"}], "apps": [{"name": "Halo"}]}}
        return {"ok": True}

    monkeypatch.setattr(R, "_invoke", fake_invoke)
    R._PENDING.clear()
    return st, calls, monkeypatch


def _online(monkeypatch, ids):
    monkeypatch.setattr(R, "_connected", lambda: ids)


def test_status_reports_down_when_bridge_offline(wired):
    st, calls, mp = wired
    _online(mp, [])
    req = Req("GET", "/status")
    R.route(req)
    assert req.replied[0] == 200
    assert req.replied[1]["reachable"] is False


def test_start_awake_pc_dispatches_connect(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    req = Req("POST", "/start", {"target": "Mac", "game": "Halo"})
    R.route(req)
    skills = [c[1] for c in calls if len(c) == 3]
    assert "game_stream_ready" in skills
    assert "game_stream_connect" in skills


def test_start_asleep_returns_pending_and_requests_wake(wired):
    st, calls, mp = wired
    _online(mp, [])
    req = Req("POST", "/start", {"target": "Mac", "game": "Halo"})
    R.route(req)
    assert req.replied[1]["status"] == "pending"
    assert ("wake",) in calls
    assert len(R._PENDING) == 1


def test_pending_connect_completes_on_awake_event(wired):
    st, calls, mp = wired
    _online(mp, [])
    R.route(Req("POST", "/start", {"target": "Mac", "game": "Halo"}))
    calls.clear()
    R.complete_pending("pc")
    skills = [c[1] for c in calls if len(c) == 3]
    assert "game_stream_connect" in skills
    assert len(R._PENDING) == 0


def test_pending_times_out(wired):
    st, calls, mp = wired
    R._PENDING.append({"pc": "pc", "target": {"kind": "mac", "host": "gpc"}, "app": "Halo",
                       "srs": False, "deadline": 0.0})
    R._reap(now=10_000_000_000.0)
    assert len(R._PENDING) == 0


def test_start_with_local_game_sets_stream_running_session(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    mp.setattr(R, "_current_game", lambda: "Halo")
    R.route(Req("POST", "/start", {"target": "Mac", "game": "Doom"}))
    connect = [c for c in calls if len(c) == 3 and c[1] == "game_stream_connect"][0]
    assert connect[2]["stream_running_session"] is True


def test_pair_forwards_pin(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    R.route(Req("POST", "/pair", {"device": "Mac", "pin": "1234"}))
    pair = [c for c in calls if len(c) == 3 and c[1] == "game_stream_pair"][0]
    assert pair[2]["pin"] == "1234"


# ── needs_login / username passthrough (wrong-login vs offline) ─────────
def test_status_passes_needs_login_through(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    mp.setattr(R, "_invoke", lambda *a, **k: {"ok": True, "data": {
        "reachable": False, "needs_login": True, "paired": [], "apps": []}})
    req = Req("GET", "/status")
    R.route(req)
    assert req.replied[1]["reachable"] is False
    assert req.replied[1]["needs_login"] is True


def test_status_offline_is_not_needs_login(wired):
    st, calls, mp = wired
    _online(mp, [])
    req = Req("GET", "/status")
    R.route(req)
    assert req.replied[1]["reachable"] is False
    assert req.replied[1]["needs_login"] is False


def test_detect_passes_username_and_needs_login(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    mp.setattr(R, "_invoke", lambda *a, **k: {"ok": True, "data": {
        "running": True, "needs_login": True, "username": "admin"}})
    R.route(req := Req("GET", "/detect"))
    body = req.replied[1]
    assert body["online"] is True and body["running"] is True
    assert body["needs_login"] is True
    assert body["username"] == "admin"


def test_detect_offline_has_blank_username(wired):
    st, calls, mp = wired
    _online(mp, [])
    R.route(req := Req("GET", "/detect"))
    body = req.replied[1]
    assert body["online"] is False
    assert body["needs_login"] is False
    assert body["username"] == ""


def test_detect_forwards_log_path(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    mp.setattr(R, "_settings", lambda: {"log_path": "C:/Sunshine/sunshine.log"})
    seen = {}

    def fake(did, skill, args, timeout=20):
        seen["args"] = args
        return {"ok": True, "data": {"running": True, "needs_login": False, "username": ""}}

    mp.setattr(R, "_invoke", fake)
    R.route(Req("GET", "/detect"))
    assert seen["args"]["log_path"] == "C:/Sunshine/sunshine.log"


def test_pair_surfaces_auth_detail(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    mp.setattr(R, "_invoke", lambda *a, **k: {
        "ok": False, "detail": "Sunshine rejected the login — check your Sunshine password"})
    R.route(req := Req("POST", "/pair", {"device": "TV", "pin": "1234"}))
    assert req.replied[1]["ok"] is False
    assert "password" in req.replied[1]["detail"].lower()


# ── pairing through Sunshine's real API: pending requests + pairing_id ──────
PID = "13270f21e5f70861ecdfd7ae0a10ff4f"
PENDING = [{"id": PID, "name": "roth", "address": "192.168.1.69"}]


def test_pairings_offline_is_409(wired):
    st, calls, mp = wired
    _online(mp, [])
    R.route(req := Req("GET", "/pairings"))
    assert req.replied[0] == 409
    assert req.replied[1]["ok"] is False and req.replied[1]["offline"] is True


def test_pairings_lists_pending_requests_from_the_pc(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    seen = {}

    def fake(did, skill, args, timeout=20):
        seen.update(did=did, skill=skill, args=args)
        return {"ok": True, "data": {"pairings": PENDING, "needs_login": False, "reachable": True}}

    mp.setattr(R, "_invoke", fake)
    R.route(req := Req("GET", "/pairings"))
    assert req.replied[0] == 200
    body = req.replied[1]
    assert body["ok"] is True
    assert body["pairings"] == PENDING
    assert body["needs_login"] is False and body["reachable"] is True
    assert seen["did"] == "pc" and seen["skill"] == "game_stream_pending"
    assert seen["args"]["sunshine"]["user"] == "a"


def test_pairings_passes_needs_login(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    mp.setattr(R, "_invoke", lambda *a, **k: {"ok": True, "data": {
        "pairings": [], "needs_login": True, "reachable": True}})
    R.route(req := Req("GET", "/pairings"))
    assert req.replied[1]["needs_login"] is True
    assert req.replied[1]["pairings"] == []


def test_pairings_old_pc_client_says_update(wired, monkeypatch):
    # The real device_bridge envelope when the PC's jc-client predates game_stream_pending.
    from api import device_bridge
    st, calls, mp = wired
    _online(mp, ["pc"])
    monkeypatch.undo()   # drop the wired fake _invoke; use the real one over a faked bridge
    monkeypatch.setattr(R, "store", lambda: st)
    monkeypatch.setattr(R, "_pc_id", lambda: "pc")
    monkeypatch.setattr(R, "_connected", lambda: ["pc"])
    monkeypatch.setattr(R, "_sunshine_conn", lambda: {"user": "a", "password": "b"})
    monkeypatch.setattr(device_bridge, "invoke_skill", lambda did, skill, args, timeout=20: {
        "ok": False, "error": "device has no skill named 'game_stream_pending'"})
    R.route(req := Req("GET", "/pairings"))
    body = req.replied[1]
    assert body["ok"] is False
    assert body["pairings"] == []
    assert "update" in body["detail"].lower()


def test_pair_forwards_pairing_id_device_and_pin(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    R.route(Req("POST", "/pair", {"device": "Roth", "pin": "1234", "pairing_id": PID}))
    pair = [c for c in calls if len(c) == 3 and c[1] == "game_stream_pair"][0]
    assert pair[2]["pairing_id"] == PID
    assert pair[2]["device"] == "Roth"
    assert pair[2]["pin"] == "1234"


def test_pair_passes_detail_and_pairings_through(wired):
    st, calls, mp = wired
    _online(mp, ["pc"])
    two = PENDING + [{"id": "0" * 32, "name": "Shield", "address": "b"}]
    mp.setattr(R, "_invoke", lambda *a, **k: {
        "ok": False, "detail": "Several devices are waiting — pick one", "pairings": two})
    R.route(req := Req("POST", "/pair", {"pin": "1234"}))
    body = req.replied[1]
    assert body["ok"] is False
    assert body["detail"] == "Several devices are waiting — pick one"
    assert body["pairings"] == two


def test_invoke_turns_a_transport_failure_into_a_detail(monkeypatch):
    from api import device_bridge
    monkeypatch.setattr(device_bridge, "invoke_skill",
                        lambda did, skill, args, timeout=20: {"ok": False, "error": "device offline"})
    assert R._invoke("pc", "game_stream_pair", {}) == {"ok": False, "detail": "device offline"}


def test_invoke_unwraps_the_real_envelope_for_pair(monkeypatch):
    from api import device_bridge
    monkeypatch.setattr(device_bridge, "invoke_skill", lambda did, skill, args, timeout=20: {
        "ok": True, "result": {"ok": True, "detail": "Paired roth"}})
    assert R._invoke("pc", "game_stream_pair", {}) == {"ok": True, "detail": "Paired roth"}
