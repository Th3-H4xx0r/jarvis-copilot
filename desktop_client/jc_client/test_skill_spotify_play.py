"""Tests for the `spotify_play` Mac skill.

The Web API sends a play to whatever Spotify player is active — his iPhone after a car
drive — and says "done" (HTTP 204) while nothing plays on the Mac (2026-10-20 23:34). The
Mac's Spotify app takes the song itself over AppleScript, opening if it's closed.

Run from the ``desktop_client`` directory:
    python3 -m pytest jc_client/test_skill_spotify_play.py -q
"""
from __future__ import annotations

import subprocess

import pytest

from jc_client.skills import _REGISTRY
from jc_client.skills import mac

TRACK = "spotify:track:0VjIjW4GlUZAMYd2vXMi3b"


class _Spotify:
    """Fake osascript talking to Spotify: answers "state|url|name", records plays."""

    def __init__(self):
        self.now = "stopped||"
        self.after_plays = ["playing|" + TRACK + "|Blinding Lights"]
        self.plays: list[str] = []
        self.scripts: list[str] = []
        self.refuse = ""

    def __call__(self, args, **kw):
        assert args[0] == "osascript"
        script = args[args.index("-e") + 1]
        self.scripts.append(script)
        if self.refuse:
            raise subprocess.CalledProcessError(1, args, output="", stderr=self.refuse)
        if "play track" in script:
            self.plays.append(args[-1])
            self.now = self.after_plays.pop(0) if self.after_plays else self.now
            return subprocess.CompletedProcess(args, 0, "", "")
        return subprocess.CompletedProcess(args, 0, self.now + "\n", "")


@pytest.fixture
def spotify(monkeypatch):
    fake = _Spotify()
    monkeypatch.setattr(mac.subprocess, "run", fake)
    monkeypatch.setattr(mac.time, "sleep", lambda s: None)
    return fake


def test_registered_for_the_server():
    entry = _REGISTRY["spotify_play"]
    assert entry["input_schema"]["required"] == ["uri"]


def test_the_song_plays_in_the_mac_spotify_app(spotify):
    result = mac.spotify_play(TRACK)
    assert spotify.plays == [TRACK]
    assert result == {"ok": True, "playing": True, "uri": TRACK, "track": "Blinding Lights"}


def test_the_uri_is_an_argument_never_part_of_the_script(spotify):
    mac.spotify_play(TRACK)
    assert all(TRACK not in s for s in spotify.scripts)


def test_only_a_spotify_uri_is_played(spotify):
    for bad in ("https://open.spotify.com/track/0VjIjW4GlUZAMYd2vXMi3b", "spotify:track:x\" & quit",
                "", "spotify:user:abc"):
        with pytest.raises(ValueError):
            mac.spotify_play(bad)
    assert spotify.scripts == []


def test_a_spotify_that_just_opened_and_dropped_the_play_gets_it_again(spotify):
    spotify.after_plays = ["stopped||", "playing|" + TRACK + "|Blinding Lights"]
    result = mac.spotify_play(TRACK)
    assert spotify.plays == [TRACK, TRACK]
    assert result["playing"] is True


def test_a_play_that_never_starts_says_so(spotify):
    spotify.after_plays = ["paused|" + TRACK + "|Blinding Lights", "paused|" + TRACK + "|Blinding Lights"]
    result = mac.spotify_play(TRACK)
    assert result["ok"] is True and result["playing"] is False
    assert "note" in result


def test_without_automation_permission_it_says_where_to_allow_it(spotify):
    spotify.refuse = "execution error: Not authorized to send Apple events to Spotify. (-1743)"
    with pytest.raises(RuntimeError, match="Automation"):
        mac.spotify_play(TRACK)
