"""game_stream skill: per-device connect drivers + dispatch + registration."""
from __future__ import annotations

import types

import pytest

from jc_client.skills import game_stream
from jc_client import skills as skills_registry


class FakeRun:
    def __init__(self, returncode=0, stderr="", raise_exc=None):
        self.calls = []
        self.returncode = returncode
        self.stderr = stderr
        self.raise_exc = raise_exc

    def __call__(self, cmd, timeout=15):
        self.calls.append(cmd)
        if self.raise_exc:
            raise self.raise_exc
        return types.SimpleNamespace(returncode=self.returncode, stderr=self.stderr, stdout="")


def test_connect_mac_builds_moonlight_cli():
    run = FakeRun()
    res = game_stream.connect({"kind": "mac", "host": "gpc"}, "Cyberpunk 2077", run=run)
    assert res["ok"] is True
    assert run.calls[0] == ["moonlight", "stream", "gpc", "Cyberpunk 2077"]


def test_connect_androidtv_adb_intent():
    run = FakeRun()
    res = game_stream.connect(
        {"kind": "androidtv", "host": "gpc-uuid", "tv_addr": "10.0.0.5:5555"}, "Halo", run=run)
    assert res["ok"] is True
    assert ["adb", "connect", "10.0.0.5:5555"] in run.calls
    launch = run.calls[-1]
    assert "am" in launch and "start" in launch
    assert any("Halo" in str(part) for part in launch)


def test_connect_ios_returns_push_marker():
    res = game_stream.connect({"kind": "ios", "host": "gpc"}, "DOOM")
    assert res.get("push") is True
    assert res["app"] == "DOOM"


def test_running_session_streams_desktop_not_relaunch():
    run = FakeRun()
    game_stream.connect({"kind": "mac", "host": "gpc"}, "Cyberpunk 2077",
                        stream_running_session=True, run=run)
    cmd = run.calls[0]
    assert "Desktop" in cmd
    assert "Cyberpunk 2077" not in cmd


def test_missing_adb_returns_actionable_error():
    run = FakeRun(raise_exc=FileNotFoundError())
    res = game_stream.connect(
        {"kind": "androidtv", "host": "gpc", "tv_addr": "10.0.0.5:5555"}, "Halo", run=run)
    assert res["ok"] is False
    assert "adb" in res["detail"].lower()


def test_target_not_paired_clear_message():
    run = FakeRun(returncode=1, stderr="Pairing required")
    res = game_stream.connect({"kind": "mac", "host": "gpc"}, "Halo", run=run)
    assert res["ok"] is False
    assert "pairing required" in res["detail"].lower()


def test_register_adds_skills():
    game_stream.register()
    game_stream.register_host()
    names = {s["name"] for s in skills_registry.all_manifest()}
    assert "game_stream_connect" in names
    assert "game_stream_status" in names
