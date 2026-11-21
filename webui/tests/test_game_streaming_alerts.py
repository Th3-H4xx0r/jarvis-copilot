"""Game streaming alerts: unknown-device (dedup), stream start/stop, Sunshine-down transition."""
from __future__ import annotations

import pytest

from api import game_streaming_alerts as A


@pytest.fixture
def pushes(monkeypatch):
    seen = []
    monkeypatch.setattr(A, "_push", lambda title, body, data=None: seen.append((title, body, data)))
    A.reset()
    return seen


def test_unknown_device_alert_fires_once(pushes):
    A.emit({"kind": "device_connect", "client": "TV-x", "unknown": True})
    A.emit({"kind": "device_connect", "client": "TV-x", "unknown": True})
    assert len(pushes) == 1
    assert "TV-x" in pushes[0][1]


def test_known_device_no_alert(pushes):
    A.emit({"kind": "device_connect", "client": "Mac", "unknown": False})
    assert pushes == []


def test_stream_start_and_stop_alert(pushes):
    A.emit({"kind": "stream_start", "client": "Mac", "app": "Halo"})
    A.emit({"kind": "stream_stop"})
    assert len(pushes) == 2


def test_down_fires_only_after_first_reachable(pushes):
    A.note_reachable(False)      # never been up -> suppressed
    assert pushes == []
    A.note_reachable(True)
    A.note_reachable(False)      # up -> down -> alert
    assert len(pushes) == 1
    assert "down" in pushes[0][0].lower()


def test_pair_request_alert_once_per_request(pushes):
    A.emit({"kind": "pair_request", "client": "Roth", "id": "a" * 32})
    A.emit({"kind": "pair_request", "client": "Roth", "id": "a" * 32})
    assert len(pushes) == 1
    assert "Roth" in pushes[0][1] and "pair" in pushes[0][0].lower()
