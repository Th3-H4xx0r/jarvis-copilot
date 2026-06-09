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


def test_match_cwd_ambiguous_gives_up():
    # Several live rows share the cwd: a recency GUESS writes the event's
    # state onto a sibling session (the cross-session "waiting" bug). Give up;
    # the poll loops reconcile within ~5s and the banner labels by cwd anyway.
    m = FakeManager()
    m.store.sessions = [
        {"id": "a", "status": "running", "cwd": "/x", "last_activity_at": 100},
        {"id": "b", "status": "running", "cwd": "/x", "last_activity_at": 200},
    ]
    assert cr._match_live_session(m.store, cwd="/x") is None


def test_match_none_when_only_stopped():
    m = FakeManager()
    m.store.sessions = [{"id": "a", "status": "stopped", "cwd": "/x"}]
    assert cr._match_live_session(m.store, cwd="/x") is None


def test_match_tmux_scoped_to_sender_device():
    # Mac tmux names are bare numbers, so the same name can exist on two
    # devices — the sender's device_id must pick ITS row, not the first hit.
    m = FakeManager()
    m.store.sessions = [
        {"id": "a", "status": "running", "tmux_name": "2", "cwd": "/x",
         "device_id": "dev-A"},
        {"id": "b", "status": "running", "tmux_name": "2", "cwd": "/y",
         "device_id": "dev-B"},
    ]
    assert cr._match_live_session(
        m.store, tmux_name="2", device_id="dev-B")["id"] == "b"
    # No device_id (old client / server hook) keeps the unscoped behavior.
    assert cr._match_live_session(m.store, tmux_name="2")["id"] == "a"


def test_match_cwd_scoped_to_sender_device():
    m = FakeManager()
    m.store.sessions = [
        {"id": "a", "status": "running", "cwd": "/x", "device_id": "dev-A",
         "last_activity_at": 999},
        {"id": "b", "status": "running", "cwd": "/x", "device_id": "dev-B",
         "last_activity_at": 1},
    ]
    # Unscoped would pick the most-recent ("a"); the device scope must win.
    assert cr._match_live_session(m.store, cwd="/x", device_id="dev-B")["id"] == "b"


def test_match_csid_scoped_when_device_known():
    # After resume-to-server the Mac claude and the server session SHARE one
    # csid — a device-tagged hook must NOT stamp the other host's row.
    m = FakeManager()
    m.store.sessions = [
        {"id": "srv", "status": "running", "cwd": "/x",
         "claude_session_id": "csid-1", "device_id": None, "host": "server"},
        {"id": "mac", "status": "running", "cwd": "/x",
         "claude_session_id": "csid-1", "device_id": "dev-A"},
    ]
    assert cr._match_live_session(
        m.store, claude_session_id="csid-1", device_id="dev-A")["id"] == "mac"
    # No device on the event → global csid match still works.
    assert cr._match_live_session(
        m.store, claude_session_id="csid-1")["id"] == "srv"


def test_match_never_targets_transcript_history_rows():
    # discovered-transcript rows are HISTORY (status "idle" puts them in the
    # live set) and NOTHING ever clears a state written onto them — a hook
    # firing before the discovery scan creates the tmux row must not poison one.
    m = FakeManager()
    m.store.sessions = [{"id": "h", "status": "idle", "cwd": "/x",
                         "claude_session_id": "csid-1",
                         "source": "discovered-transcript"}]
    assert cr._match_live_session(m.store, claude_session_id="csid-1") is None
    assert cr._match_live_session(m.store, cwd="/x") is None


def test_match_jc_name_falls_back_unscoped():
    # Jarvis-LAUNCHED rows carry no device_id; the device-scoped pass misses
    # them but the jc- name is unique, so the unscoped fallback must find it.
    # Bare user names ("2") must NOT fall back across devices.
    m = FakeManager()
    m.store.sessions = [
        {"id": "launched", "status": "running", "tmux_name": "jc-abc123",
         "cwd": "/x", "device_id": None},
        {"id": "other-dev", "status": "running", "tmux_name": "2",
         "cwd": "/y", "device_id": "dev-B"},
    ]
    assert cr._match_live_session(
        m.store, tmux_name="jc-abc123", device_id="dev-A")["id"] == "launched"
    assert cr._match_live_session(
        m.store, tmux_name="2", device_id="dev-A") is None


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


# ── waiting-prompt pane parsing (chat-view "needs input" modal) ──────────────

def test_parse_pane_prompt_permission_box():
    raw = ("╭──────────────────────────╮\n"
           "│ Bash command             │\n"
           "│   rm -rf build           │\n"
           "│ Do you want to proceed?  │\n"
           "│ ❯ 1. Yes                 │\n"
           "│   2. Yes, don't ask again│\n"
           "│   3. No, tell Claude     │\n"
           "╰──────────────────────────╯")
    q, opts = cr._parse_pane_prompt(raw)
    assert q == "Do you want to proceed?"
    assert [(o["key"], o["label"]) for o in opts] == [
        ("1", "Yes"), ("2", "Yes, don't ask again"), ("3", "No, tell Claude")]


def test_parse_pane_prompt_restarts_on_new_menu():
    raw = ("1. old\n2. older\n"
           "Which approach?\n"
           "❯ 1. Rewrite\n  2. Patch\n")
    q, opts = cr._parse_pane_prompt(raw)
    assert q == "Which approach?"
    assert [o["label"] for o in opts] == ["Rewrite", "Patch"]


def test_parse_pane_prompt_no_options():
    q, opts = cr._parse_pane_prompt("Overwrite file? (y/n)")
    assert opts == [] and q is None
