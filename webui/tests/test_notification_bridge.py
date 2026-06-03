"""Notification-tap bridge — server-side unit tests.

Covers the visible-vs-silent push decision, the action-banner composer, the
APNs/FCM visible payload builders, the poll filter + expiry in take_mobile_queue,
and the fire-and-forget behavior for foreground-required skills.

See docs/superpowers/specs/2026-06-03-notification-tap-bridge-design.md.
"""
import os
import sys
import threading
import time as _time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from api.device_bridge import (  # noqa: E402
    is_foreground_skill, format_action_banner, _FOREGROUND_SKILLS,
)
from api.push.apns import _build_apns_body, _apns_headers  # noqa: E402
from api.push.fcm import _build_fcm_message  # noqa: E402
from api import device_bridge as db  # noqa: E402
import api.device_bridge as dbridge  # noqa: E402


# ── Task 1: foreground set + banner ────────────────────────────────────────

def test_foreground_skill_membership():
    assert is_foreground_skill("phone_control")
    assert is_foreground_skill("open_url")
    assert is_foreground_skill("open_app")
    assert is_foreground_skill("run_shortcut")
    assert is_foreground_skill("send_sms")
    assert not is_foreground_skill("battery_level")
    assert not is_foreground_skill("get_location")
    assert not is_foreground_skill("")


def test_banner_open_url_uses_host():
    title, body = format_action_banner("open_url", {"url": "https://www.google.com/search?q=x"})
    assert title == "Open www.google.com"
    assert body == "Tap to run"


def test_banner_open_app_uses_app_name():
    title, _ = format_action_banner("open_app", {"app": "Spotify"})
    assert "Spotify" in title


def test_banner_phone_control_brightness():
    title, _ = format_action_banner("phone_control", {"action": "brightness", "value": 0.2})
    assert title == "Set brightness 20%"


def test_banner_phone_control_wifi_off():
    title, _ = format_action_banner("phone_control", {"action": "wifi", "value": 0})
    assert title == "Turn off Wi-Fi"


def test_banner_unknown_skill_falls_back():
    title, body = format_action_banner("some_new_skill", {})
    assert title == "JARVIS action ready"
    assert body == "Tap to run"


def test_banner_brightness_missing_value_is_graceful():
    title, _ = format_action_banner("phone_control", {"action": "brightness"})
    assert title == "Set brightness"  # no "None"


def test_banner_non_dict_args_does_not_crash():
    assert format_action_banner("open_app", None)[0] == "Open app"
    assert format_action_banner("phone_control", ["weird"])[0] == "Phone control"


def test_banner_title_is_clamped():
    title, _ = format_action_banner("open_app", {"app": "X" * 500})
    assert len(title) <= 100


# ── Task 2: APNs visible payload ───────────────────────────────────────────

def test_apns_silent_body_when_no_alert():
    body = _build_apns_body({"type": "invoke_pending"}, None)
    assert body["aps"].get("content-available") == 1
    assert "alert" not in body["aps"]
    assert body["jarviscopilot"] == {"type": "invoke_pending"}


def test_apns_visible_body_when_alert():
    body = _build_apns_body({"type": "invoke_pending"}, {"title": "Open google", "body": "Tap to run"})
    assert body["aps"]["alert"] == {"title": "Open google", "body": "Tap to run"}
    assert body["aps"].get("sound") == "default"
    assert "content-available" not in body["aps"]
    assert body["jarviscopilot"] == {"type": "invoke_pending"}


def test_apns_headers_silent_vs_alert():
    cfg = {"key_id": "K", "team_id": "T", "topic": "com.x"}
    silent = _apns_headers(cfg, "JWT", alert=False)
    assert silent["apns-push-type"] == "background"
    assert silent["apns-priority"] == "5"
    visible = _apns_headers(cfg, "JWT", alert=True)
    assert visible["apns-push-type"] == "alert"
    assert visible["apns-priority"] == "10"
    assert visible["apns-topic"] == "com.x"


# ── Task 3: FCM visible payload ────────────────────────────────────────────

def test_fcm_data_only_when_no_alert():
    msg = _build_fcm_message("TOK", {"type": "invoke_pending", "device_id": "d1"}, None)
    assert msg["token"] == "TOK"
    assert msg["data"] == {"type": "invoke_pending", "device_id": "d1"}
    assert "notification" not in msg
    assert msg["android"]["priority"] == "HIGH"


def test_fcm_notification_when_alert():
    msg = _build_fcm_message("TOK", {"type": "invoke_pending"}, {"title": "Open google", "body": "Tap to run"})
    assert msg["notification"] == {"title": "Open google", "body": "Tap to run"}
    assert msg["data"] == {"type": "invoke_pending"}


# ── Task 4: poll filter + expiry ───────────────────────────────────────────

def _seed_queue(device_id, items):
    with db._PENDING_MOBILE_LOCK:
        db._PENDING_MOBILE[device_id] = list(items)


def test_take_queue_foreground_true_returns_all_and_clears():
    _seed_queue("dev1", [
        {"call_id": "a", "skill": "open_url", "args": {}, "requires_foreground": True,
         "expires_at": _time.time() + 100},
        {"call_id": "b", "skill": "battery_level", "args": {}, "requires_foreground": False,
         "expires_at": _time.time() + 100},
    ])
    out = db.take_mobile_queue("dev1", include_foreground=True)
    assert {e["call_id"] for e in out} == {"a", "b"}
    assert db.pending_mobile_count("dev1") == 0


def test_take_queue_background_withholds_foreground():
    _seed_queue("dev2", [
        {"call_id": "a", "skill": "open_url", "args": {}, "requires_foreground": True,
         "expires_at": _time.time() + 100},
        {"call_id": "b", "skill": "battery_level", "args": {}, "requires_foreground": False,
         "expires_at": _time.time() + 100},
    ])
    out = db.take_mobile_queue("dev2", include_foreground=False)
    assert {e["call_id"] for e in out} == {"b"}
    assert db.pending_mobile_count("dev2") == 1


def test_take_queue_drops_expired_and_resolves_waiter():
    holder = {"event": threading.Event(), "result": None, "error": None, "device_id": "dev3"}
    with db._MOBILE_CALL_EVENTS_LOCK:
        db._MOBILE_CALL_EVENTS["old"] = holder
    _seed_queue("dev3", [
        {"call_id": "old", "skill": "battery_level", "args": {}, "requires_foreground": False,
         "expires_at": _time.time() - 1},
    ])
    out = db.take_mobile_queue("dev3", include_foreground=True)
    assert out == []
    assert holder["event"].is_set()
    assert "expired" in (holder["error"] or "")
    with db._MOBILE_CALL_EVENTS_LOCK:
        db._MOBILE_CALL_EVENTS.pop("old", None)


# ── Task 5: tag + visible push + fire-and-forget ───────────────────────────

class _FakePush:
    def __init__(self):
        self.calls = []

    def send(self, kind, token, payload, *, timeout=10.0, alert=None):
        self.calls.append({"kind": kind, "token": token, "payload": payload, "alert": alert})
        return {"ok": True}


def _patch_device(monkeypatch, fake_push):
    # `_invoke_via_mobile_push` does `from api import push` / `from api.pairing
    # import list_devices`, which read the already-bound module attributes — so
    # we patch the real modules, not sys.modules.
    import api.push as real_push
    import api.pairing as real_pairing
    monkeypatch.setattr(real_pairing, "list_devices", lambda: [{
        "id": "devF", "push_token": "TOK", "push_kind": "apns", "kind": "mobile-ios",
    }], raising=False)
    monkeypatch.setattr(real_pairing, "update_device_fields",
                        lambda *a, **k: None, raising=False)
    monkeypatch.setattr(real_push, "send", fake_push.send)


def test_foreground_skill_is_fire_and_forget_with_visible_push(monkeypatch):
    fake = _FakePush()
    _patch_device(monkeypatch, fake)
    with dbridge._PENDING_MOBILE_LOCK:
        dbridge._PENDING_MOBILE.pop("devF", None)
    res = dbridge.invoke_skill("devF", "open_url", {"url": "https://google.com"}, timeout=2.0)
    assert res["ok"] is True
    assert res["result"]["queued"] is True
    assert "tap" in res["result"]["note"].lower()
    assert len(fake.calls) == 1
    assert fake.calls[0]["alert"]["title"] == "Open google.com"
    q = dbridge._PENDING_MOBILE["devF"]
    assert q[0]["requires_foreground"] is True
    assert q[0]["expires_at"] > _time.time()


def test_non_foreground_skill_sends_silent_push(monkeypatch):
    fake = _FakePush()
    _patch_device(monkeypatch, fake)
    with dbridge._PENDING_MOBILE_LOCK:
        dbridge._PENDING_MOBILE.pop("devF", None)
    res = dbridge.invoke_skill("devF", "battery_level", {}, timeout=0.2)
    assert fake.calls[0]["alert"] is None
    assert res["ok"] is False


class _FailingPush:
    def send(self, kind, token, payload, *, timeout=10.0, alert=None):
        return {"ok": False, "error": "not configured"}  # no 404/410 status


def test_foreground_skill_push_failure_reports_error_not_success(monkeypatch):
    import api.push as real_push
    import api.pairing as real_pairing
    monkeypatch.setattr(real_pairing, "list_devices", lambda: [{
        "id": "devG", "push_token": "TOK", "push_kind": "apns", "kind": "mobile-ios",
    }], raising=False)
    monkeypatch.setattr(real_pairing, "update_device_fields",
                        lambda *a, **k: None, raising=False)
    monkeypatch.setattr(real_push, "send", _FailingPush().send)
    with dbridge._PENDING_MOBILE_LOCK:
        dbridge._PENDING_MOBILE.pop("devG", None)
    res = dbridge.invoke_skill("devG", "open_url", {"url": "https://x.com"}, timeout=2.0)
    # must NOT claim "sent to your phone" when the push never went out
    assert res["ok"] is False
    assert "reach" in res["error"].lower()
    # and the stranded queue entry is dropped
    assert dbridge.pending_mobile_count("devG") == 0
