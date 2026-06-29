"""Photon (iMessage) as a Claude Code notification channel.

Covers the two coding_routes changes: the channel is merged into the notify
settings (off by default), and ``_dispatch_coding_notifications`` fires the
Photon send only when the channel is enabled for that event.
"""

from __future__ import annotations

import importlib

cr = importlib.import_module("api.coding_routes")


class _FakeStore:
    def __init__(self, notifications=None):
        self._notifications = notifications

    def get_setting(self, key, default=None):
        if key == "notifications":
            return self._notifications
        return default


def test_photon_in_channels_and_defaults_off():
    assert "photon" in cr._NOTIFY_CHANNELS
    merged = cr._merge_notify_settings(None)
    for ekey in ("finished", "needs_input", "error"):
        assert merged["events"][ekey]["photon"] is False


def test_merge_honors_stored_photon_true():
    stored = {"events": {"finished": {"photon": True}}}
    merged = cr._merge_notify_settings(stored)
    assert merged["events"]["finished"]["photon"] is True
    # Untouched events keep the default.
    assert merged["events"]["error"]["photon"] is False


def test_dispatch_fires_photon_when_enabled(monkeypatch):
    calls = []
    monkeypatch.setattr(cr, "_send_coding_photon", lambda text: (calls.append(text) or True))
    # Avoid the other channels' side effects.
    monkeypatch.setattr(cr, "_push_device_alert", lambda *a, **k: 0)
    monkeypatch.setattr(cr, "_notify_webui_event", lambda **k: None)
    monkeypatch.setattr(cr, "_send_coding_telegram", lambda text: False)

    store = _FakeStore({"events": {"needs_input": {
        "telegram": False, "mobile": False, "toast": False, "photon": True}}})
    sent = cr._dispatch_coding_notifications(store, event="notification", row=None, cwd="/x/proj")
    assert sent.get("photon") is True
    assert len(calls) == 1


def test_dispatch_skips_photon_when_disabled(monkeypatch):
    calls = []
    monkeypatch.setattr(cr, "_send_coding_photon", lambda text: (calls.append(text) or True))
    monkeypatch.setattr(cr, "_push_device_alert", lambda *a, **k: 0)
    monkeypatch.setattr(cr, "_notify_webui_event", lambda **k: None)
    monkeypatch.setattr(cr, "_send_coding_telegram", lambda text: False)

    store = _FakeStore({"events": {"needs_input": {"photon": False}}})
    sent = cr._dispatch_coding_notifications(store, event="notification", row=None, cwd="/x/proj")
    assert "photon" not in sent
    assert calls == []
