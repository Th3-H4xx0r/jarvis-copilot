"""Game-streaming power subsystem: power topic -> Sunshine-log watcher -> game_stream events."""
from __future__ import annotations

import json
import sys

from jc_client.game_stream_power import GameStreamPower, default_log_path


class FakeWatcher:
    instances = []

    def __init__(self, client, known, emit, log_path=None, app_names=None):
        self.app_names = app_names or {}
        self.client = client
        self.known = set(known or ())
        self.emit = emit
        self.log_path = log_path
        self.started = False
        self.stopped = False
        FakeWatcher.instances.append(self)

    def start(self):
        self.started = True

    def stop(self):
        self.stopped = True


class FakeClient:
    def __init__(self, host, port, user, password, scheme="https"):
        self.args = (host, port, user, password, scheme)

    def get_clients(self):
        return [{"name": "Mac"}, {"name": "Living Room TV"}, {"name": None}]


def _subsystem(sent):
    FakeWatcher.instances = []
    return GameStreamPower(lambda f: sent.append(f),
                           client_factory=FakeClient, watcher_factory=FakeWatcher, poll_pairs=False)


def test_power_on_starts_watcher_with_log_path_and_known_certs():
    sent = []
    gs = _subsystem(sent)
    gs.handle_power({"on": True, "log_path": "/var/log/sunshine.log",
                     "sunshine": {"host": "gpc", "port": 47990, "user": "a", "password": "b"}})
    assert len(FakeWatcher.instances) == 1
    w = FakeWatcher.instances[0]
    assert w.started is True
    assert w.log_path == "/var/log/sunshine.log"
    assert w.known == {"Mac", "Living Room TV"}   # None name dropped


def test_watcher_events_are_forwarded_up_as_game_stream():
    sent = []
    gs = _subsystem(sent)
    gs.handle_power({"on": True, "sunshine": {"host": "gpc"}})
    w = FakeWatcher.instances[0]
    w.emit({"kind": "stream_start", "app": "Halo"})
    assert sent == [{"type": "event", "name": "game_stream",
                     "data": {"kind": "stream_start", "app": "Halo"}}]


def test_power_off_stops_the_watcher():
    sent = []
    gs = _subsystem(sent)
    gs.handle_power({"on": True, "sunshine": {"host": "gpc"}})
    w = FakeWatcher.instances[0]
    gs.handle_power({"on": False})
    assert w.stopped is True
    gs.handle_power({"on": True, "sunshine": {"host": "gpc"}})   # restarts
    assert len(FakeWatcher.instances) == 2


def test_second_on_is_idempotent():
    sent = []
    gs = _subsystem(sent)
    gs.handle_power({"on": True, "sunshine": {"host": "gpc"}})
    gs.handle_power({"on": True, "sunshine": {"host": "gpc"}})
    assert len(FakeWatcher.instances) == 1


def test_no_log_path_falls_back_to_os_default():
    sent = []
    gs = _subsystem(sent)
    gs.handle_power({"on": True, "sunshine": {"host": "gpc"}})
    assert FakeWatcher.instances[0].log_path == default_log_path()


def test_sunshine_unavailable_still_watches_with_empty_known():
    sent = []

    class Boom(FakeClient):
        def get_clients(self):
            raise RuntimeError("Sunshine down")

    FakeWatcher.instances = []
    gs = GameStreamPower(lambda f: sent.append(f),
                         client_factory=Boom, watcher_factory=FakeWatcher)
    gs.handle_power({"on": True, "sunshine": {"host": "gpc"}})
    assert len(FakeWatcher.instances) == 1
    assert FakeWatcher.instances[0].known == set()
    assert FakeWatcher.instances[0].started is True


def test_default_log_path_is_os_specific():
    p = default_log_path()
    if sys.platform == "win32":
        assert p.endswith("sunshine.log") and "Sunshine" in p
    else:
        assert p.endswith(".config/sunshine/sunshine.log")


def test_seed_known_without_host_uses_localhost():
    # The server no longer sends a host (Sunshine is localhost on the PC). Seeding must
    # still read the paired clients, or every device that connects reads as "unknown".
    sent = []
    gs = _subsystem(sent)
    gs.handle_power({"on": True, "log_path": "/tmp/sunshine.log",
                     "sunshine": {"user": "root", "password": "pw", "scheme": "https"}})
    w = FakeWatcher.instances[-1]
    assert w.known == {"Mac", "Living Room TV"}


class PairClient(FakeClient):
    pending = [{"id": "a" * 32, "name": "Roth", "address": "192.168.1.69"}]

    def pending_pairings(self):
        return list(PairClient.pending)


def _pair_events(sent):
    return [f["data"] for f in sent if f.get("name") == "game_stream" and f["data"].get("kind") == "pair_request"]


def test_pair_request_poll_emits_each_request_once():
    sent = []
    gs = GameStreamPower(lambda f: sent.append(f), client_factory=PairClient,
                         watcher_factory=FakeWatcher, poll_pairs=False)
    c = PairClient("127.0.0.1", 47990, "root", "pw")
    PairClient.pending = [{"id": "a" * 32, "name": "Roth", "address": "192.168.1.69"}]
    gs._poll_pairs_once(c)
    gs._poll_pairs_once(c)
    evs = _pair_events(sent)
    assert len(evs) == 1
    assert evs[0]["client"] == "Roth" and evs[0]["id"] == "a" * 32


def test_pair_request_alerts_again_after_it_clears():
    sent = []
    gs = GameStreamPower(lambda f: sent.append(f), client_factory=PairClient,
                         watcher_factory=FakeWatcher, poll_pairs=False)
    c = PairClient("127.0.0.1", 47990, "root", "pw")
    PairClient.pending = [{"id": "b" * 32, "name": "Tablet", "address": "x"}]
    gs._poll_pairs_once(c)
    PairClient.pending = []
    gs._poll_pairs_once(c)
    PairClient.pending = [{"id": "b" * 32, "name": "Tablet", "address": "x"}]
    gs._poll_pairs_once(c)
    assert len(_pair_events(sent)) == 2


def test_sunshine_apps_maps_commands_to_names(tmp_path):
    from jc_client.game_stream_power import sunshine_apps
    (tmp_path / "apps.json").write_text(json.dumps({"apps": [
        {"name": "Desktop"},
        {"name": "Steam Big Picture", "cmd": "steam://open/bigpicture"},
        {"name": "Thing", "detached": ["thing.exe --go"]},
    ]}))
    names = sunshine_apps(str(tmp_path / "sunshine.log"))
    assert names["steam://open/bigpicture"] == "Steam Big Picture"
    assert names["thing.exe --go"] == "Thing"
    assert names["Desktop"] == "Desktop"
