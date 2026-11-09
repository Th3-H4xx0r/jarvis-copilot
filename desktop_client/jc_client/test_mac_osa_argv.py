"""App names and window titles reach osascript as argv, never inside the script.

A web page controls its own window title. Escaping only `"` let a title like
`a\\" & (do shell script "…") --` close the AppleScript string and run a shell
command when Jarvis moved, minimised or restored that window.
"""
from __future__ import annotations

import subprocess

import pytest

from jc_client.skills import mac

PAYLOAD = 'a\\" & (do shell script "touch /tmp/pwned") --'


@pytest.fixture
def calls(monkeypatch):
    seen = []

    def fake_run(argv, **kw):
        seen.append(list(argv))
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(mac.subprocess, "run", fake_run)
    return seen


def _assert_payload_only_in_argv(argv):
    assert argv[0] == "osascript" and argv[1] == "-e"
    script = argv[2]
    assert PAYLOAD not in script and "do shell script" not in script
    assert PAYLOAD in argv[3:]


def test_quit_app_passes_the_name_as_argv(calls):
    mac.quit_app(PAYLOAD)
    _assert_payload_only_in_argv(calls[-1])


def test_window_attr_passes_app_and_title_as_argv(calls):
    mac._set_window_attr("Safari", PAYLOAD, "position", "{10, 20}")
    _assert_payload_only_in_argv(calls[-1])
    mac._set_window_attr(PAYLOAD, "Title", "size", "{300, 200}")
    _assert_payload_only_in_argv(calls[-1])


def test_window_minimize_passes_app_and_title_as_argv(calls):
    mac._set_window_minimized("Safari", PAYLOAD, True)
    _assert_payload_only_in_argv(calls[-1])


def test_focus_window_passes_app_and_title_as_argv(calls, monkeypatch):
    monkeypatch.setattr(mac, "list_windows", lambda: {"windows": [{"app": PAYLOAD, "title": PAYLOAD}]})
    mac.focus_window("a")
    _assert_payload_only_in_argv(calls[-1])


def test_window_restore_activates_by_argv(calls, monkeypatch):
    monkeypatch.setattr(mac, "_find_window", lambda sub: {"app": PAYLOAD, "title": PAYLOAD})
    mac.window_restore("anything")
    for argv in calls:
        _assert_payload_only_in_argv(argv)
