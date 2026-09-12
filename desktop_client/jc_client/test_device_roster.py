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
