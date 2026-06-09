"""Tests for the Code Master control plane: settings endpoint, the settings-gated
notification dispatch, and the more-robust live-session matching that keeps the
LA/WebUI on the instant (hook) path instead of the slow reconcile poll.
"""
from __future__ import annotations

import pytest

from api import coding_routes as cr
from api.coding_routes import handle_coding_request


class FakeStore:
    def __init__(self):
        self._settings = {}
        self.sessions = []
        self.updated = []

    # settings
    def get_setting(self, key, default=None):
        return self._settings.get(key, default)

    def set_setting(self, key, value):
        self._settings[key] = value

    # sessions
    def list_sessions(self, **kw):
        return [dict(s) for s in self.sessions]

    def update_session(self, sid, **fields):
        self.updated.append((sid, fields))
        for s in self.sessions:
            if s["id"] == sid:
                s.update(fields)

    # misc used by alert-text / la helpers
    def list_projects(self):
        return []

    def get_project(self, pid):
        return None

    def list_la_tokens(self):
        return []


class FakeManager:
    def __init__(self):
        self.store = FakeStore()


# ── /settings ────────────────────────────────────────────────────────────────

def test_settings_get_returns_defaults():
    m = FakeManager()
    status, body = handle_coding_request("GET", "/settings", None, manager=m)
    assert status == 200
    s = body["settings"]
    assert s["events"]["finished"]["telegram"] is True
    assert s["events"]["needs_input"]["mobile"] is True
    assert s["usage_display"] is True


def test_settings_post_merges_persists_and_ignores_junk():
    m = FakeManager()
    payload = {"events": {"finished": {"telegram": False}},
               "usage_display": False, "junk": 123}
    status, body = handle_coding_request("POST", "/settings", payload, manager=m)
    assert status == 200
    s = body["settings"]
    assert s["events"]["finished"]["telegram"] is False   # overridden
    assert s["events"]["finished"]["mobile"] is True       # default kept
    assert s["usage_display"] is False
    assert "junk" not in s                                 # unknown keys dropped
    # persisted to the store
    assert m.store.get_setting("notifications")["usage_display"] is False


# ── notification dispatch (settings-gated) ───────────────────────────────────

def _spy_channels(monkeypatch):
    calls = {"tg": 0, "mob": 0, "toast": 0}
    monkeypatch.setattr(cr, "_send_coding_telegram",
                        lambda text: (calls.__setitem__("tg", calls["tg"] + 1) or True))
    monkeypatch.setattr(cr, "_push_device_alert",
                        lambda t, b: (calls.__setitem__("mob", calls["mob"] + 1) or 1))
    monkeypatch.setattr(cr, "_notify_webui_event",
                        lambda **kw: calls.__setitem__("toast", calls["toast"] + 1))
    return calls


def test_dispatch_sends_mobile_and_toast_not_telegram(monkeypatch):
    # _dispatch owns MOBILE push + WebUI toast. Telegram is sent by the plugin's
    # notify.sh hook (the proven `jc-client notify` path), so _dispatch must NOT
    # send it here (avoids a double Telegram ping per event).
    m = FakeManager()  # defaults: all channels on
    calls = _spy_channels(monkeypatch)
    sent = cr._dispatch_coding_notifications(m.store, event="notification",
                                            row=None, cwd="/x/proj")
    assert calls == {"tg": 0, "mob": 1, "toast": 1}
    assert sent.get("mobile") is True and sent.get("toast") is True
    assert "telegram" not in sent


def test_dispatch_respects_channel_matrix(monkeypatch):
    m = FakeManager()
    m.store.set_setting("notifications", {"events": {
        "finished": {"telegram": True, "mobile": True, "toast": False}}})
    calls = _spy_channels(monkeypatch)
    cr._dispatch_coding_notifications(m.store, event="stop", row=None, cwd="/x/proj")
    # mobile on -> sent; toast off -> not; telegram never sent here (notify.sh owns it)
    assert calls == {"tg": 0, "mob": 1, "toast": 0}


def test_dispatch_unknown_event_is_noop(monkeypatch):
    m = FakeManager()
    monkeypatch.setattr(cr, "_send_coding_telegram",
                        lambda t: pytest.fail("must not send for unmapped event"))
    assert cr._dispatch_coding_notifications(
        m.store, event="user_prompt_submit", row=None, cwd="/x") == {}


# ── robust live-session matching ─────────────────────────────────────────────

def test_match_tmux_takes_priority():
    m = FakeManager()
    m.store.sessions = [{"id": "a", "status": "running", "tmux_name": "jc-1", "cwd": "/x"}]
    assert cr._match_live_session(m.store, tmux_name="jc-1")["id"] == "a"


def test_match_cwd_multiple_picks_most_recent():
    m = FakeManager()
    m.store.sessions = [
        {"id": "a", "status": "running", "cwd": "/x", "last_activity_at": 100},
        {"id": "b", "status": "running", "cwd": "/x", "last_activity_at": 200},
    ]
    row = cr._match_live_session(m.store, cwd="/x")
    assert row["id"] == "b"  # ambiguous cwd → most-recent, not a give-up


def test_match_none_when_only_stopped():
    m = FakeManager()
    m.store.sessions = [{"id": "a", "status": "stopped", "cwd": "/x"}]
    assert cr._match_live_session(m.store, cwd="/x") is None


# ── /activity-event integration ──────────────────────────────────────────────

def test_activity_event_matched_updates_and_dispatches(monkeypatch):
    m = FakeManager()
    m.store.sessions = [{"id": "a", "status": "running", "tmux_name": "jc-1",
                         "cwd": "/x", "activity_state": "working"}]
    monkeypatch.setattr(cr, "_push_coding_now", lambda store: None)
    monkeypatch.setattr(cr, "_notify_webui", lambda: None)
    fired = {}
    monkeypatch.setattr(cr, "_dispatch_coding_notifications",
                        lambda store, **kw: (fired.update(kw) or {"telegram": True}))
    status, body = handle_coding_request(
        "POST", "/activity-event", {"event": "stop", "tmux_name": "jc-1"}, manager=m)
    assert status == 200
    assert body["matched"] is True and body["changed"] is True
    assert body["state"] == "idle"
    assert m.store.sessions[0]["activity_state"] == "idle"
    assert fired.get("event") == "stop"


def test_activity_event_unmatched_still_dispatches(monkeypatch):
    m = FakeManager()  # no sessions → no match
    fired = {}
    monkeypatch.setattr(cr, "_dispatch_coding_notifications",
                        lambda store, **kw: (fired.update(kw) or {"telegram": True}))
    status, body = handle_coding_request(
        "POST", "/activity-event", {"event": "stop", "cwd": "/x"}, manager=m)
    assert status == 200
    assert body["matched"] is False
    assert fired.get("event") == "stop"  # notifications fire even without a match
