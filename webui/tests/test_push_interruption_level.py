"""Alarm pushes: time-sensitive interruption level, and a fan-out that honours each phone's app."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from api import push  # noqa: E402
from api.push import apns  # noqa: E402


def test_interruption_level_rides_in_aps():
    body = apns._build_apns_body({"type": "door"}, {"title": "Front Door", "body": "Opened",
                                                    "interruption_level": "time-sensitive"})
    assert body["aps"]["interruption-level"] == "time-sensitive"
    assert body["aps"]["alert"] == {"title": "Front Door", "body": "Opened"}


def test_no_level_means_no_key_and_unknown_levels_are_dropped():
    plain = apns._build_apns_body({}, {"title": "t", "body": "b"})
    assert "interruption-level" not in plain["aps"]
    odd = apns._build_apns_body({}, {"title": "t", "body": "b", "interruption_level": "loud"})
    assert "interruption-level" not in odd["aps"]


def test_alert_phones_uses_each_devices_topic_and_environment(monkeypatch):
    devices = [
        {"id": "a", "kind": "mobile-ios", "push_kind": "apns", "push_token": "tok-a",
         "push_topic": "com.example.wearables", "push_env": "development"},
        {"id": "b", "kind": "mobile-ios", "push_kind": "apns", "push_token": "tok-b"},
        {"id": "c", "kind": "browser", "push_kind": "apns", "push_token": "tok-c"},
        {"id": "d", "kind": "mobile-ios", "push_kind": "", "push_token": ""},
    ]
    sent = []

    def fake_send(token, payload, **kw):
        sent.append((token, payload, kw))
        return {"ok": True}

    monkeypatch.setattr(push, "send_apns", fake_send)
    monkeypatch.setattr(push, "_mobile_devices", lambda: devices)
    n = push.alert_phones("Door alarm", "Front Door opened", data={"type": "door"},
                          category="DOOR_ALARM", level="time-sensitive")
    assert n == 2
    by_token = {t: kw for t, _p, kw in sent}
    assert by_token["tok-a"]["topic"] == "com.example.wearables"
    assert by_token["tok-a"]["sandbox"] is True
    assert by_token["tok-b"]["topic"] is None and by_token["tok-b"]["sandbox"] is None
    assert by_token["tok-a"]["alert"] == {"title": "Door alarm", "body": "Front Door opened",
                                          "category": "DOOR_ALARM", "interruption_level": "time-sensitive"}
