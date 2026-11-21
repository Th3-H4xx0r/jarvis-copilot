"""Sunshine log watcher: parse events + derive the live flag + flag unknown devices."""
from __future__ import annotations

from jc_client.sunshine_watcher import parse_log_line, SunshineWatcher


def test_parse_known_start_stop_lines():
    start = parse_log_line("[2026:11:21:10:00:00]: Info: Launching [Cyberpunk 2077]")
    assert start["kind"] == "stream_start"
    assert start["app"] == "Cyberpunk 2077"
    stop = parse_log_line("[2026:11:21:10:30:00]: Info: CLIENT DISCONNECTED")
    assert stop["kind"] == "stream_stop"


def test_unknown_line_returns_none():
    assert parse_log_line("[2026:11:21:10:00:00]: Info: Configuration parsed") is None
    assert parse_log_line("garbage line") is None


def test_device_connect_not_in_known_is_unknown():
    w = SunshineWatcher(client=None, known_certs={"Mac"}, emit=lambda e: None)
    ev = w.process_line("[2026:11:21:10:00:00]: Info: CLIENT CONNECTED [TV-livingroom]")
    assert ev["kind"] == "device_connect"
    assert ev["client"] == "TV-livingroom"
    assert ev["unknown"] is True


def test_rejoining_known_cert_not_flagged():
    w = SunshineWatcher(client=None, known_certs={"Mac"}, emit=lambda e: None)
    ev = w.process_line("[2026:11:21:10:00:00]: Info: CLIENT CONNECTED [Mac]")
    assert ev["unknown"] is False


def test_derive_live_active_flag():
    w = SunshineWatcher(client=None, known_certs=set(), emit=lambda e: None)
    assert w.derive_live()["active"] is False
    w.process_line("[2026:11:21:10:00:00]: Info: Launching [Cyberpunk 2077]")
    live = w.derive_live()
    assert live["active"] is True
    assert live["app"] == "Cyberpunk 2077"
    w.process_line("[2026:11:21:10:30:00]: Info: CLIENT DISCONNECTED")
    assert w.derive_live()["active"] is False
