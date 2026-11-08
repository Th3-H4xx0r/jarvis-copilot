"""Signing a paired device out drops only the tokens its pairing issued."""
import api.auth as auth
from api import devices_routes


def test_sign_out_drops_only_the_devices_tokens(monkeypatch):
    sessions = {"abcd1234.x": 1, "abcd1234.y": 2, "zzzz9999.browser": 3}
    monkeypatch.setattr(auth, "_sessions", sessions)
    monkeypatch.setattr(auth, "_save_sessions", lambda s: None)
    assert devices_routes._sign_out({"id": "phone", "session_prefix": "abcd1234"}) == 2
    assert list(sessions) == ["zzzz9999.browser"]


def test_a_device_without_a_session_prefix_signs_nobody_else_out(monkeypatch):
    # Logout used to match an empty prefix against every token: the browser's too.
    sessions = {"abcd1234.x": 1, "zzzz9999.browser": 3}
    monkeypatch.setattr(auth, "_sessions", sessions)
    monkeypatch.setattr(auth, "_save_sessions", lambda s: None)
    assert devices_routes._sign_out({"id": "old-phone", "session_prefix": ""}) == 0
    assert len(sessions) == 2
