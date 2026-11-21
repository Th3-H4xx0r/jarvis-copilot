"""Sunshine log watcher against the strings Sunshine really writes (src/stream.cpp,
src/process.cpp): CLIENT CONNECTED / CLIENT DISCONNECTED carry no names; the app shows up as
"Executing [Desktop]" / "Executing: [cmd] in [dir]" / "Spawning [cmd] in [dir]"."""
from __future__ import annotations

from jc_client.sunshine_watcher import parse_log_line, SunshineWatcher

P = "[2026-11-21 03:22:00.322]: Info: "


def test_parse_real_sunshine_lines():
    assert parse_log_line(P + "CLIENT CONNECTED")["kind"] == "stream_start"
    assert parse_log_line(P + "CLIENT DISCONNECTED")["kind"] == "stream_stop"
    ex = parse_log_line(P + "Executing [Desktop]")
    assert ex["kind"] == "app_exec" and ex["app"] == "Desktop"
    cmd = parse_log_line(P + "Executing: [steam://open/bigpicture] in [C:\\Steam]")
    assert cmd["kind"] == "app_exec" and cmd["app"] == "steam://open/bigpicture"
    sp = parse_log_line(P + "Spawning [steam://open/bigpicture] in [C:\\Steam]")
    assert sp["kind"] == "app_exec" and sp["app"] == "steam://open/bigpicture"


def test_prep_commands_are_not_the_app():
    assert parse_log_line(P + "Executing Do Cmd: [prep.bat]") is None
    assert parse_log_line(P + "Executing Undo Cmd: [undo.bat]") is None


def test_unrelated_lines_return_none():
    assert parse_log_line(P + "Desktop resolution [2560x1440]") is None
    assert parse_log_line(P + "Web UI: [127.0.0.1] -- not authorized") is None
    assert parse_log_line("garbage line") is None


def test_stream_start_carries_the_last_executed_app_name():
    w = SunshineWatcher(None, set(), lambda e: None,
                        app_names={"steam://open/bigpicture": "Steam Big Picture"})
    assert w.process_line(P + "Executing: [steam://open/bigpicture] in [C:\\Steam]") is None
    ev = w.process_line(P + "CLIENT CONNECTED")
    assert ev["kind"] == "stream_start" and ev["app"] == "Steam Big Picture"
    assert w.derive_live() == {"active": True, "client": None, "app": "Steam Big Picture"}


def test_desktop_stream_then_disconnect():
    w = SunshineWatcher(None, set(), lambda e: None)
    w.process_line(P + "Executing [Desktop]")
    assert w.process_line(P + "CLIENT CONNECTED")["app"] == "Desktop"
    stop = w.process_line(P + "CLIENT DISCONNECTED")
    assert stop["kind"] == "stream_stop"
    assert w.derive_live()["active"] is False
