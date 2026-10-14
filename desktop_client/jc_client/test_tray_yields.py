"""The Python tray steps aside when the native Jarvis Mac app is running (it
owns the menu-bar item now), and comes back when the app's marker is stale."""
import os

from jc_client import tray


def test_live_marker_means_the_app_owns_the_menu_bar(tmp_path, monkeypatch):
    marker = tmp_path / "mac-app.running"
    monkeypatch.setattr(tray, "_mac_app_marker", lambda: str(marker))
    assert tray._mac_app_running() is False
    marker.write_text(str(os.getpid()))  # a live pid
    assert tray._mac_app_running() is True


def test_stale_marker_is_ignored(tmp_path, monkeypatch):
    marker = tmp_path / "mac-app.running"
    marker.write_text("999999")  # no such process
    monkeypatch.setattr(tray, "_mac_app_marker", lambda: str(marker))
    assert tray._mac_app_running() is False
    marker.write_text("not a pid")
    assert tray._mac_app_running() is False
