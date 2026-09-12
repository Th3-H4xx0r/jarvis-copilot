"""How devices and wearables are worded in the tray menu.

The fetch itself is network; what is worth pinning is the shaping — a status dot
that matches the state, a wearable matched to the right picture, and an offline
device saying when it was last around rather than nothing at all.
"""
from __future__ import annotations

from jc_client.device_roster import DeviceRow, _ago, kind_symbol, wearable_kind


def test_the_dot_follows_the_state():
    assert DeviceRow("iPhone", "mobile-ios", True).dot == "🟢"
    assert DeviceRow("iPhone", "mobile-ios", False).dot == "⚪️"


def test_a_row_says_what_is_wrong_only_when_something_is():
    assert DeviceRow("iPhone", "mobile-ios", True).title == "🟢  iPhone"
    row = DeviceRow("Board", "browser", False, "last seen 1d ago")
    assert row.title == "⚪️  Board — last seen 1d ago"


def test_every_wearable_finds_its_picture():
    assert wearable_kind("Colmi R12", "R12_7E04") == "ring"
    assert wearable_kind("VSITOO S1 Pro", "VSITOO-S1-Pro") == "bottle"
    assert wearable_kind("Etekcity ESF551", "Etekcity Smart Fitness Scale") == "scale"
    assert wearable_kind("Jarvis ESP32 DevKit V1", "Jarvis-ESP32-33DA") == "esp32"
    assert wearable_kind("Something else", "Mystery") == ""


def test_device_kinds_map_to_symbols():
    assert kind_symbol("mobile-ios") == "iphone"
    assert kind_symbol("desktop") == "laptopcomputer"
    assert kind_symbol("browser") == "globe"
    assert kind_symbol("watch") == "applewatch"
    assert kind_symbol("") == "display"


def test_last_seen_reads_in_the_largest_useful_unit():
    assert _ago(5) == "just now"
    assert _ago(600) == "10m ago"
    assert _ago(7200) == "2h ago"
    assert _ago(180000) == "2d ago"
