"""How devices and wearables are worded in the tray menu.

The fetch itself is network; what is worth pinning is the shaping — a status dot
that matches the state, a wearable matched to the right picture, and an offline
device saying when it was last around rather than nothing at all.
"""
from __future__ import annotations

from jc_client.device_roster import DeviceRow, _ago, kind_symbol, wearable_kind


def test_a_row_says_what_is_wrong_only_when_something_is():
    assert DeviceRow("iPhone", "mobile-ios", True).title == "iPhone"
    row = DeviceRow("Board", "browser", False, "last seen 1d ago")
    assert row.title == "Board — last seen 1d ago"


def test_titles_carry_no_decoration():
    """The title is also the key the macOS styling matches rows on, and what
    non-Mac trays show verbatim — so it stays plain."""
    title = DeviceRow("R12_7E04", "wearable", True, "Connected", "ring").title
    assert title == "R12_7E04 — Connected"
    assert not any(ch in title for ch in "🟢⚪️●")


def test_every_wearable_finds_its_picture():
    assert wearable_kind("Colmi R12", "R12_7E04") == "ring"
    assert wearable_kind("VSITOO S1 Pro", "VSITOO-S1-Pro") == "bottle"
    assert wearable_kind("Etekcity ESF551", "Etekcity Smart Fitness Scale") == "scale"
    assert wearable_kind("Jarvis ESP32 DevKit V1", "Jarvis-ESP32-33DA") == "esp32"
    assert wearable_kind("Something else", "Mystery") == ""


def test_device_kinds_map_to_symbols():
    assert kind_symbol("mobile-ios") == "iphone"
    assert kind_symbol("desktop") == "laptopcomputer"
    assert kind_symbol("browser") == "safari"
    assert kind_symbol("watch") == "applewatch"
    assert kind_symbol("") == "display"


def test_the_name_decides_when_the_kind_cannot():
    """Everything paired through a web page is recorded as "browser" — the Mac
    and the ESP32 board included — so a globe on all of them says nothing."""
    assert kind_symbol("browser", "Jarvis-ESP32 board") == "cpu"
    assert kind_symbol("browser", "Pranavs-MacBook-Pro.local") == "laptopcomputer"
    assert kind_symbol("browser", "Macbook Pro Web") == "laptopcomputer"
    assert kind_symbol("browser", "Some random tab") == "safari"


def test_last_seen_reads_in_the_largest_useful_unit():
    assert _ago(5) == "just now"
    assert _ago(600) == "10m ago"
    assert _ago(7200) == "2h ago"
    assert _ago(180000) == "2d ago"


class _FakeClient:
    """Answers /api/devices from `devices`; records every other request."""

    def __init__(self, devices):
        self.devices = devices
        self.calls = []

    def request_json(self, method, path, body=None):
        import json
        from types import SimpleNamespace
        self.calls.append((method, path))
        if path == "/api/devices":
            return SimpleNamespace(body=json.dumps({"devices": self.devices}))
        return SimpleNamespace(body=json.dumps({"ok": True, "result": {"devices": [
            {"model": "R12", "name": "Ring", "connected": True, "status": "Connected"}]}}))


def _phone(**extra):
    return {"id": "phone-1", "name": "iPhone", "kind": "mobile-ios", "online": True, "invokable": True,
            "bridge_connected": True, "skills": [{"name": "wearables_list"}], **extra}


def test_reported_wearables_are_read_without_asking_the_phone(monkeypatch):
    from jc_client import device_roster
    client = _FakeClient([_phone(wearables=[{"model": "HBand smart band", "name": "Band", "connected": False}])])
    monkeypatch.setattr(device_roster, "_client", lambda: client)
    rows, error = device_roster.fetch()
    assert error == ""
    assert client.calls == [("GET", "/api/devices")]
    band = [r for r in rows if r.kind == "wearable"]
    assert [(r.name, r.online, r.detail, r.wearable) for r in band] == [("Band", False, "Not connected", "band")]


def test_an_older_phone_is_still_asked(monkeypatch):
    from jc_client import device_roster
    client = _FakeClient([_phone()])
    monkeypatch.setattr(device_roster, "_client", lambda: client)
    rows, _ = device_roster.fetch()
    assert ("POST", "/api/devices/skills/invoke") in client.calls
    assert [r.name for r in rows if r.kind == "wearable"] == ["Ring"]


def test_a_disconnected_phones_report_is_not_shown_as_live(monkeypatch):
    import time as _time
    from jc_client import device_roster
    client = _FakeClient([_phone(bridge_connected=False, wearables_at=_time.time() - 600,
                                 wearables=[{"model": "R12", "name": "Ring", "connected": True}])])
    monkeypatch.setattr(device_roster, "_client", lambda: client)
    rows, _ = device_roster.fetch()
    ring = [r for r in rows if r.kind == "wearable"]
    assert [(r.online, r.detail) for r in ring] == [(False, "phone last reported 10m ago")]
    assert client.calls == [("GET", "/api/devices")]
