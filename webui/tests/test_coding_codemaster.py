"""Tests for the Code Master control plane: settings endpoint and the
settings-gated notification dispatch.
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


def test_a_save_that_leaves_a_switch_out_keeps_it():
    """An app that doesn't know a switch (an older phone build, the web page)
    must not turn it off by saving its own settings (the phone-instructions
    switch stayed off this way)."""
    m = FakeManager()
    handle_coding_request("POST", "/settings", {"remote_instructions": True, "remote_approvals": True},
                          manager=m)
    _, body = handle_coding_request("POST", "/settings", {"usage_display": False}, manager=m)
    s = body["settings"]
    assert s["remote_instructions"] is True and s["remote_approvals"] is True
    assert s["usage_display"] is False
    _, body = handle_coding_request("POST", "/settings", {"remote_instructions": False}, manager=m)
    assert body["settings"]["remote_instructions"] is False


# ── notification dispatch (settings-gated) ───────────────────────────────────

def _spy_channels(monkeypatch):
    cr._last_alert.clear()  # isolate the per-(session,event) phone-ping debounce
    calls = {"tg": 0, "mob": 0, "toast": 0, "device": 0}
    monkeypatch.setattr(cr, "_send_coding_telegram",
                        lambda text: (calls.__setitem__("tg", calls["tg"] + 1) or True))
    monkeypatch.setattr(cr, "_push_device_alert",
                        lambda t, b, data=None, wake=False: (calls.__setitem__("mob", calls["mob"] + 1) or 1))
    monkeypatch.setattr(cr, "_notify_webui_event",
                        lambda **kw: calls.__setitem__("toast", calls["toast"] + 1))
    monkeypatch.setattr(cr, "_send_coding_device_notify",
                        lambda ch, t, b: (calls.__setitem__("device", calls["device"] + 1) or True))
    return calls


def test_dispatch_sends_all_enabled_channels(monkeypatch):
    # _dispatch is the SINGLE source of truth for coding notifications: it owns
    # Telegram, mobile push, and the WebUI toast, each gated by the Code Master
    # matrix. (Telegram used to be sent client-side by notify.sh, ignoring the
    # matrix — that path is retired.)
    m = FakeManager()  # defaults: all channels on
    calls = _spy_channels(monkeypatch)
    sent = cr._dispatch_coding_notifications(m.store, event="notification",
                                            row=None, cwd="/x/proj")
    assert calls == {"tg": 1, "mob": 1, "toast": 1, "device": 0}
    assert sent.get("telegram") is True
    assert sent.get("mobile") is True and sent.get("toast") is True


def test_dispatch_respects_channel_matrix(monkeypatch):
    m = FakeManager()
    m.store.set_setting("notifications", {"events": {
        "finished": {"telegram": True, "mobile": True, "toast": False}}})
    calls = _spy_channels(monkeypatch)
    cr._dispatch_coding_notifications(m.store, event="stop", row=None, cwd="/x/proj")
    # telegram + mobile on -> sent; toast off -> not.
    assert calls == {"tg": 1, "mob": 1, "toast": 0, "device": 0}


def test_dispatch_telegram_unchecked_is_not_sent(monkeypatch):
    # Regression: unchecking Telegram in the Code Master matrix must actually
    # stop the Telegram ping (the Mac-session bug where notify.sh fired Telegram
    # regardless of the matrix). Other enabled channels still fire.
    m = FakeManager()
    m.store.set_setting("notifications", {"events": {
        "finished": {"telegram": False, "mobile": True, "toast": True}}})
    calls = _spy_channels(monkeypatch)
    sent = cr._dispatch_coding_notifications(m.store, event="stop",
                                             row=None, cwd="/x/proj")
    assert calls == {"tg": 0, "mob": 1, "toast": 1, "device": 0}
    assert "telegram" not in sent  # disabled channel: absent, never sent


def test_dispatch_unknown_event_is_noop(monkeypatch):
    m = FakeManager()
    monkeypatch.setattr(cr, "_send_coding_telegram",
                        lambda t: pytest.fail("must not send for unmapped event"))
    assert cr._dispatch_coding_notifications(
        m.store, event="user_prompt_submit", row=None, cwd="/x") == {}


# ── what a banner says ───────────────────────────────────────────────────────

def test_alert_text_names_the_project_then_the_folder():
    """The tracker hands over the session (agent, project, project_id, cwd)."""
    class S:
        def get_project(self, pid):
            return {"name": "IntelliStock"} if pid == "p1" else None

    row = {"agent": "claude", "project": "intel", "project_id": "p1", "cwd": "/x/intel"}
    assert cr._coding_alert_text(S(), row, "stop") == ("✅ Claude finished", "IntelliStock")
    assert cr._coding_alert_text(S(), dict(row, project_id=None), "notification") == \
        ("🔔 Claude needs you", "intel")
    assert cr._coding_alert_text(S(), {"agent": "codex", "cwd": "/x/app/"}, "stop") == \
        ("✅ Codex finished", "app")


def test_one_session_rings_once_per_edge(monkeypatch):
    """The debounce keys on the tracker's session key."""
    m = FakeManager()
    calls = _spy_channels(monkeypatch)
    row = {"id": "d1|claude|s1", "agent": "claude", "cwd": "/x/a"}
    cr._dispatch_coding_notifications(m.store, event="stop", row=row, cwd="/x/a")
    cr._dispatch_coding_notifications(m.store, event="stop", row=row, cwd="/x/a")
    assert calls["mob"] == 1 and calls["tg"] == 1


def test_focus_only_waiting_mutes_finished_pushes(monkeypatch):
    """The iPhone's Focus filter: while it's on, only what waits on you reaches the phone."""
    from api import coding_routes as cr

    class S:
        def __init__(self):
            self.s = {"agents_focus": {"only_waiting": True}}

        def get_setting(self, k, d=None):
            return self.s.get(k, d)

        def get_project(self, pid):
            return None

    pushed = []
    monkeypatch.setattr(cr, "_push_device_alert", lambda t, b, data=None, wake=False: pushed.append(t) or 1)
    monkeypatch.setattr(cr, "_send_coding_telegram", lambda text: True)
    monkeypatch.setattr(cr, "_alert_debounce_ok", lambda sid, ev: True)
    store = S()
    cr._dispatch_coding_notifications(store, event="stop", row={"id": "r", "cwd": "/w/a"})
    assert pushed == []
    cr._dispatch_coding_notifications(store, event="notification", row={"id": "r", "cwd": "/w/a"})
    assert len(pushed) == 1


# ── device cards (glasses, ring…) wake the app ──────────────────────────────

def _phones(monkeypatch):
    from api import pairing, push as push_mod
    monkeypatch.setattr(pairing, "list_devices", lambda: [
        {"kind": "mobile-ios", "push_kind": "apns", "push_token": "tok"},
        {"kind": "browser", "push_kind": "apns", "push_token": "mac"}])
    sent = []
    monkeypatch.setattr(push_mod, "send",
                        lambda kind, token, payload, alert=None, **kw: sent.append((token, payload, alert)) or {"ok": True})
    return sent


def test_a_device_card_shows_and_wakes_the_app(monkeypatch):
    """Code Master → glasses: with the phone locked an alert-only push never ran the
    app, so nothing put the card on the lens unless the ESP32 relay was running."""
    sent = _phones(monkeypatch)
    assert cr._send_coding_device_notify("glasses", "✅ Claude finished", "jarvis-copilot") is True
    assert len(sent) == 1, "phones only"
    token, payload, alert = sent[0]
    assert payload["type"] == "device_notify" and payload["channel"] == "glasses"
    assert alert == {"title": "✅ Claude finished", "body": "jarvis-copilot", "wake": True}


def test_a_device_card_can_wake_without_a_second_banner(monkeypatch):
    sent = _phones(monkeypatch)
    cr._send_coding_device_notify("glasses", "Claude has a question", "app: Which DB?", banner=False)
    _, payload, alert = sent[0]
    assert alert is None, "the phone already shows its own banner"
    assert (payload["notify_title"], payload["notify_body"]) == ("Claude has a question", "app: Which DB?")


def test_the_phones_banner_carries_the_glasses_card(monkeypatch):
    """Finished with Mobile + Glasses on: one push — the phone's banner, carrying
    the card and waking the app — not a second banner for the glasses."""
    m = FakeManager()
    cr._last_alert.clear()
    from api import device_bridge
    monkeypatch.setattr(device_bridge, "all_device_notification_channels",
                        lambda: [{"key": "glasses", "label": "Glasses", "default_on": True}])
    banners, cards = [], []
    monkeypatch.setattr(cr, "_push_device_alert",
                        lambda t, b, data=None, wake=False: banners.append((t, b, data, wake)) or 1)
    monkeypatch.setattr(cr, "_send_coding_device_notify",
                        lambda ch, t, b, app="", banner=True: cards.append(ch) or True)
    monkeypatch.setattr(cr, "_send_coding_telegram", lambda text: True)
    monkeypatch.setattr(cr, "_notify_webui_event", lambda **kw: None)
    sent = cr._dispatch_coding_notifications(m.store, event="stop", row=None, cwd="/x/proj")
    assert sent["mobile"] is True and sent["glasses"] is True
    assert cards == [], "the glasses rode on the banner"
    title, body, data, wake = banners[0]
    assert wake is True and data["notify_channel"] == "glasses"
    assert (data["notify_title"], data["notify_body"]) == (title, body)
    # Mobile off: the glasses still get their own card.
    m.store.set_setting("notifications", {"events": {"finished": {"mobile": False, "glasses": True}}})
    banners.clear()
    cr._last_alert.clear()
    sent = cr._dispatch_coding_notifications(m.store, event="stop", row=None, cwd="/x/proj")
    assert banners == [] and cards == ["glasses"] and sent["glasses"] is True
