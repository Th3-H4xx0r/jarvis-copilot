"""Tests for the `media_control` Mac skill.

Play / pause / next / previous through the system media keys, with play and
pause checked against what Core Audio says is making sound, so a pause never
starts music that wasn't playing.

Run from the ``desktop_client`` directory:
    python3 -m pytest jc_client/test_skill_media_control.py -q
"""
from __future__ import annotations

import os

import pytest

from jc_client.skills import _REGISTRY
from jc_client.skills import mac


@pytest.fixture
def keys(monkeypatch):
    pressed: list[str] = []
    monkeypatch.setattr(mac, "_press_media_key", pressed.append)
    monkeypatch.setattr(mac, "_MEDIA_POLL_S", 0)
    return pressed


def _audio(monkeypatch, *states):
    """Successive answers from Core Audio: a set of pids, or None for unknown."""
    answers = list(states)
    monkeypatch.setattr(mac, "_child_pids", lambda: set())
    monkeypatch.setattr(
        mac, "_audio_output_pids",
        lambda: answers.pop(0) if len(answers) > 1 else answers[0],
    )


def test_registered_with_every_action_in_the_schema():
    entry = _REGISTRY["media_control"]
    actions = entry["input_schema"]["properties"]["action"]["enum"]
    assert set(actions) == {"play", "pause", "toggle", "next", "previous", "status"}
    assert entry["input_schema"]["required"] == ["action"]


@pytest.mark.parametrize("action, key", [
    ("next", "media_next"),
    ("previous", "media_previous"),
])
def test_skips_press_their_media_key(monkeypatch, keys, action, key):
    _audio(monkeypatch, {4242})
    out = mac.media_control(action)
    assert keys == [key]
    assert out["ok"] is True


def test_toggle_presses_play_pause_and_reports_the_new_state(monkeypatch, keys):
    _audio(monkeypatch, {4242}, set())
    out = mac.media_control("toggle")
    assert keys == ["media_play_pause"]
    assert out["ok"] is True
    assert out["playing"] is False


def test_pause_with_nothing_playing_presses_nothing(monkeypatch, keys):
    _audio(monkeypatch, set())
    out = mac.media_control("pause")
    assert keys == []
    assert out == {"ok": True, "action": "pause", "changed": False, "playing": False,
                   "note": "nothing is playing"}


def test_play_while_already_playing_presses_nothing(monkeypatch, keys):
    _audio(monkeypatch, {4242})
    out = mac.media_control("play")
    assert keys == []
    assert out["changed"] is False
    assert out["playing"] is True


def test_pause_while_playing_presses_the_key_and_confirms_silence(monkeypatch, keys):
    _audio(monkeypatch, {4242}, set())
    out = mac.media_control("pause")
    assert keys == ["media_play_pause"]
    assert out["ok"] is True
    assert out["changed"] is True
    assert out["playing"] is False


def test_pause_that_does_not_take_reports_failure(monkeypatch, keys):
    _audio(monkeypatch, {4242})
    out = mac.media_control("pause")
    assert keys == ["media_play_pause"]
    assert out["ok"] is False
    assert out["playing"] is True


def test_play_from_silence_confirms_sound(monkeypatch, keys):
    _audio(monkeypatch, set(), set(), {4242})
    out = mac.media_control("play")
    assert keys == ["media_play_pause"]
    assert out["ok"] is True
    assert out["playing"] is True


def test_our_own_sound_does_not_count_as_playing(monkeypatch, keys):
    # Jarvis speaking its ack must not make "pause" toggle music that isn't on.
    _audio(monkeypatch, {os.getpid()})
    out = mac.media_control("pause")
    assert keys == []
    assert out["playing"] is False


def test_children_of_the_client_do_not_count_as_playing(monkeypatch, keys):
    _audio(monkeypatch, {9001})
    monkeypatch.setattr(mac, "_child_pids", lambda: {9001})
    mac.media_control("pause")
    assert keys == []


def test_unknown_state_still_presses_and_says_so(monkeypatch, keys):
    _audio(monkeypatch, None)
    out = mac.media_control("pause")
    assert keys == ["media_play_pause"]
    assert out["ok"] is True
    assert "playing" not in out
    assert "note" in out


def test_status_names_what_is_making_sound(monkeypatch, keys):
    _audio(monkeypatch, {4242})
    monkeypatch.setattr(mac, "_process_name", lambda pid: "Spotify")
    out = mac.media_control("status")
    assert keys == []
    assert out == {"ok": True, "action": "status", "playing": True, "apps": ["Spotify"]}


def test_unknown_action_is_rejected(keys):
    with pytest.raises(ValueError):
        mac.media_control("rewind")


def test_audio_output_pids_reads_core_audio():
    # Real call: whatever is playing on this machine, the answer is a set (or
    # None on a macOS without per-process audio objects) — never an exception.
    pids = mac._audio_output_pids()
    assert pids is None or isinstance(pids, set)
