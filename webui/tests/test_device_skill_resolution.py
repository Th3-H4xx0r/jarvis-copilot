"""A caller that names only a skill — an ESP32 script's jarvis.invoke — reaches the device offering it."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from api import device_bridge as db  # noqa: E402


def _rows(*pairs):
    return [{"device_id": device, "device_name": device, "name": name} for device, name in pairs]


def test_the_first_device_offering_the_skill_wins(monkeypatch):
    monkeypatch.setattr(db, "all_device_skills",
                        lambda: _rows(("mac", "chrome_snapshot"), ("phone", "ring_find"), ("tablet", "ring_find")))
    assert db.device_offering("ring_find") == "phone"


def test_the_calling_device_wins_when_it_offers_the_skill(monkeypatch):
    monkeypatch.setattr(db, "all_device_skills", lambda: _rows(("phone", "ring_find"), ("tablet", "ring_find")))
    assert db.device_offering("ring_find", caller_id="tablet") == "tablet"
    assert db.device_offering("ring_find", caller_id="mac") == "phone"


def test_an_unknown_skill_resolves_to_nothing(monkeypatch):
    monkeypatch.setattr(db, "all_device_skills", lambda: _rows(("phone", "ring_find")))
    assert db.device_offering("send_message") is None
