"""Service wiring for game streaming: the game_stream_power topic reaches the watcher
subsystem, and the PC's own topics are merged into its subscription frame."""
from __future__ import annotations

import json

from jc_client.service import Service


class FakeWs:
    def __init__(self):
        self.sent = []

    def send_text(self, text):
        self.sent.append(json.loads(text))


class SyncExec:
    def submit(self, fn, *a, **k):
        fn(*a, **k)


class FakeGameStream:
    def __init__(self):
        self.calls = []

    def handle_power(self, data):
        self.calls.append(data)


def _svc():
    svc = Service()
    svc._executor = SyncExec()
    return svc


def test_subscription_merges_pc_and_ui_topics():
    svc = _svc()
    svc._ws = FakeWs()
    svc._pc_topics = {"game_stream_power": 0.0}
    svc._ui_topics = {"pods": 1.0}
    svc._send_subscription()
    frame = svc._ws.sent[-1]
    assert frame["type"] == "subscribe"
    assert frame["topics"] == {"game_stream_power": 0.0, "pods": 1.0}


def test_game_stream_power_topic_reaches_the_watcher():
    svc = _svc()
    gs = FakeGameStream()
    svc._game_stream = gs
    svc._handle_frame(None, {"type": "topic", "topic": "game_stream_power",
                             "data": {"on": True, "sunshine": {"host": "gpc"}}})
    assert gs.calls == [{"on": True, "sunshine": {"host": "gpc"}}]


def test_other_topics_still_broadcast_to_ui():
    svc = _svc()
    svc._game_stream = FakeGameStream()
    got = []
    svc._ui_broadcast = lambda m: got.append(m)
    svc._handle_frame(None, {"type": "topic", "topic": "harness_jobs", "data": {"x": 1}})
    assert got and got[-1]["topic"] == "harness_jobs"
    assert svc._game_stream.calls == []


def test_game_stream_power_without_subsystem_falls_back_to_ui():
    svc = _svc()
    svc._game_stream = None
    got = []
    svc._ui_broadcast = lambda m: got.append(m)
    svc._handle_frame(None, {"type": "topic", "topic": "game_stream_power", "data": {"on": False}})
    assert got and got[-1]["topic"] == "game_stream_power"
