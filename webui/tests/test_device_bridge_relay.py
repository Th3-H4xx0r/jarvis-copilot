"""Tests for the MCP-relay channel on the device bridge (Phase 2, 2a)."""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from api import device_bridge as db  # noqa: E402


class _FakeSock:
    def shutdown(self, *_a):
        pass

    def close(self):
        pass


def _make_conn(device_id="dev1", monkeypatch=None):
    """A registered _DeviceConn whose _ws_send_text is captured, not sent."""
    conn = db._DeviceConn(device_id=device_id, sock=_FakeSock(), conn=None, name="desk")
    db._register(conn)
    return conn


def _capture_sends(monkeypatch):
    sent = []

    def fake_send(conn, text):
        sent.append((conn.device_id, json.loads(text)))

    monkeypatch.setattr(db, "_ws_send_text", fake_send)
    return sent


def _cleanup(device_id):
    db._unregister(device_id)


def test_open_relay_registers_session_and_sends_mcp_open(monkeypatch):
    sent = _capture_sends(monkeypatch)
    conn = _make_conn("d-open")
    try:
        frames = []
        sid = db.open_relay("d-open", on_frame=frames.append, meta={"browser": "chrome"})
        assert sid and isinstance(sid, str)
        # session registered on the conn
        assert sid in conn.relay_sessions
        # an mcp_open frame went out with the session + meta
        opens = [m for (_d, m) in sent if m.get("type") == "mcp_open"]
        assert len(opens) == 1
        assert opens[0]["session"] == sid
        assert opens[0]["meta"] == {"browser": "chrome"}
    finally:
        _cleanup("d-open")


def test_open_relay_unknown_device_returns_none(monkeypatch):
    _capture_sends(monkeypatch)
    assert db.open_relay("nope", on_frame=lambda d: None) is None


def test_relay_send_frame_emits_mcp_frame(monkeypatch):
    sent = _capture_sends(monkeypatch)
    _make_conn("d-send")
    try:
        sid = db.open_relay("d-send", on_frame=lambda d: None)
        ok = db.relay_send_frame("d-send", sid, '{"jsonrpc":"2.0","id":1}')
        assert ok is True
        frames = [m for (_d, m) in sent if m.get("type") == "mcp_frame"]
        assert frames[-1]["session"] == sid
        assert frames[-1]["data"] == '{"jsonrpc":"2.0","id":1}'
    finally:
        _cleanup("d-send")


def test_relay_send_frame_unknown_session_returns_false(monkeypatch):
    _capture_sends(monkeypatch)
    _make_conn("d-badsess")
    try:
        assert db.relay_send_frame("d-badsess", "deadbeef", "{}") is False
    finally:
        _cleanup("d-badsess")


def test_inbound_mcp_frame_routes_to_on_frame(monkeypatch):
    _capture_sends(monkeypatch)
    conn = _make_conn("d-in")
    try:
        got = []
        sid = db.open_relay("d-in", on_frame=got.append)
        db._handle_message(conn, {"type": "mcp_frame", "session": sid, "data": "HELLO"})
        assert got == ["HELLO"]
        # a frame for an unknown session is ignored, not an error
        db._handle_message(conn, {"type": "mcp_frame", "session": "x", "data": "Y"})
        assert got == ["HELLO"]
    finally:
        _cleanup("d-in")


def test_mcp_ready_error_closed_route_to_on_event(monkeypatch):
    _capture_sends(monkeypatch)
    conn = _make_conn("d-evt")
    try:
        events = []
        sid = db.open_relay("d-evt", on_frame=lambda d: None,
                            on_event=lambda kind, payload: events.append((kind, payload)))
        db._handle_message(conn, {"type": "mcp_ready", "session": sid})
        db._handle_message(conn, {"type": "mcp_error", "session": sid, "error": "boom"})
        db._handle_message(conn, {"type": "mcp_closed", "session": sid})
        kinds = [k for (k, _p) in events]
        assert kinds == ["ready", "error", "closed"]
        # mcp_closed removed the session from the registry
        assert sid not in conn.relay_sessions
    finally:
        _cleanup("d-evt")


def test_safe_close_notifies_relay_sessions(monkeypatch):
    _capture_sends(monkeypatch)
    conn = _make_conn("d-close")
    try:
        events = []
        db.open_relay("d-close", on_frame=lambda d: None,
                      on_event=lambda kind, payload: events.append(kind))
        db._safe_close(conn)
        assert "closed" in events
        assert conn.relay_sessions == {}
    finally:
        _cleanup("d-close")


def test_mcp_relay_available_marks_capable(monkeypatch):
    _capture_sends(monkeypatch)
    monkeypatch.setattr(db, "_trigger_relay_autoregister", lambda: None)
    conn = _make_conn("d-cap")
    try:
        db._handle_message(conn, {"type": "mcp_relay_available", "meta": {"browser": "chrome"}})
        assert conn.relay_capable is True
        assert conn.relay_meta == {"browser": "chrome"}
        caps = db.relay_capable_devices()
        match = [c for c in caps if c["device_id"] == "d-cap"]
        assert match and match[0]["meta"] == {"browser": "chrome"}
    finally:
        _cleanup("d-cap")


def test_relay_capable_excludes_plain_devices(monkeypatch):
    _capture_sends(monkeypatch)
    _make_conn("d-plain")
    try:
        ids = [c["device_id"] for c in db.relay_capable_devices()]
        assert "d-plain" not in ids
    finally:
        _cleanup("d-plain")


def test_close_relay_sends_mcp_close_and_drops_session(monkeypatch):
    sent = _capture_sends(monkeypatch)
    conn = _make_conn("d-cl2")
    try:
        sid = db.open_relay("d-cl2", on_frame=lambda d: None)
        db.close_relay("d-cl2", sid)
        assert sid not in conn.relay_sessions
        closes = [m for (_d, m) in sent if m.get("type") == "mcp_close"]
        assert closes and closes[-1]["session"] == sid
        # sending after close is a no-op False
        assert db.relay_send_frame("d-cl2", sid, "{}") is False
    finally:
        _cleanup("d-cl2")
