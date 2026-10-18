"""spotify_playback play when Spotify has no active device.

Real failure (CarPlay drive, phone locked): play → 404 NO_ACTIVE_DEVICE because
the phone's Spotify app wasn't running; the phone opens Spotify only after
Jarvis finishes speaking, so an immediate retry fails too. Play now falls back
to any listed device, or waits (in the background) for one to appear.
"""

from __future__ import annotations

import json
import logging

import pytest

from plugins.spotify import client as spotify_mod
from plugins.spotify import tools as spotify_tool

NO_ACTIVE_DEVICE_BODY = json.dumps({
    "error": {
        "status": 404,
        "message": "Player command failed: No active device found",
        "reason": "NO_ACTIVE_DEVICE",
    }
})
NOT_FOUND_BODY = json.dumps({"error": {"status": 404, "message": "Not found."}})

TRACK = "spotify:track:7ouMYWpwJ422jRcDASZB7P"
OTHER_TRACK = "spotify:track:0VjIjW4GlUZAMYd2vXMi3b"

PHONE = {"id": "phone-1", "name": "Pranav's iPhone", "type": "Smartphone", "is_restricted": False, "is_active": False}
TV = {"id": "tv-1", "name": "Living Room TV", "type": "TV", "is_restricted": False, "is_active": False}
RESTRICTED_PHONE = {"id": "phone-r", "name": "Work phone", "type": "Smartphone", "is_restricted": True, "is_active": False}


def _api_error(status_code: int, body: str, path: str = "/me/player/play") -> spotify_mod.SpotifyAPIError:
    err = spotify_mod.SpotifyAPIError(
        "Spotify could not find an active playback device or player session for this request.",
        status_code=status_code,
        response_body=body,
    )
    err.path = path
    return err


def _no_active_device() -> spotify_mod.SpotifyAPIError:
    return _api_error(404, NO_ACTIVE_DEVICE_BODY)


class _PlayerStub:
    """Fake SpotifyClient: scripted start_playback failures + device polls."""

    def __init__(self, *, play_errors=None, device_polls=None, playback_states=None):
        self.play_errors = list(play_errors or [])
        self.device_polls = list(device_polls or [])
        self.playback_states = list(playback_states or [])
        self.play_calls: list[dict] = []
        self.device_calls = 0
        self.pause_calls = 0
        self.transfer_calls: list[dict] = []
        self.started: dict | None = None  # what a taken play left playing, like Spotify

    def start_playback(self, **kw):
        self.play_calls.append(kw)
        if self.play_errors:
            err = self.play_errors.pop(0)
            if err is not None:
                raise err
        if kw.get("device_id"):
            uri = (kw.get("uris") or [None])[0] or kw.get("context_uri")
            self.started = {"is_playing": True, "device": {"id": kw["device_id"]}, "item": {"uri": uri},
                            "context": {"uri": kw["context_uri"]} if kw.get("context_uri") else None}
        return {"success": True, "status_code": 204, "empty": True}

    def get_devices(self):
        self.device_calls += 1
        if len(self.device_polls) > 1:
            return {"devices": self.device_polls.pop(0)}
        return {"devices": self.device_polls[0] if self.device_polls else []}

    def get_playback_state(self, **kw):
        if len(self.playback_states) > 1:
            return self.playback_states.pop(0)
        if self.playback_states:
            return self.playback_states[0]
        if self.started:
            return self.started
        return {"success": True, "status_code": 204, "empty": True}

    def transfer_playback(self, **kw):
        self.transfer_calls.append(kw)
        return {"success": True, "status_code": 204, "empty": True}

    def pause_playback(self, **kw):
        self.pause_calls += 1
        raise _api_error(404, NO_ACTIVE_DEVICE_BODY, "/me/player/pause")


class _FakeClock:
    def __init__(self):
        self.now = 0.0
        self.sleeps = 0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps += 1
        self.now += seconds


@pytest.fixture(autouse=True)
def _no_pending_leak():
    yield
    spotify_tool._cancel_pending_play()


@pytest.fixture
def spawned(monkeypatch: pytest.MonkeyPatch) -> list:
    """Capture pending plays instead of starting real poller threads."""
    captured: list = []
    monkeypatch.setattr(
        spotify_tool,
        "_spawn_pending_play_poller",
        lambda pending, client: captured.append((pending, client)),
    )
    return captured


def _play(stub, **args) -> dict:
    return json.loads(spotify_tool._handle_spotify_playback({"action": "play", **args}))


def _use(monkeypatch: pytest.MonkeyPatch, stub) -> None:
    monkeypatch.setattr(spotify_tool, "_spotify_client", lambda: stub)


# ── client: the no-active-device 404 is distinguishable ────────────────────


class _FakeResponse:
    def __init__(self, status_code: int, text: str):
        self.status_code = status_code
        self.text = text
        self.headers = {"content-type": "application/json"}
        self.content = text.encode("utf-8")

    def json(self):
        return json.loads(self.text)


@pytest.mark.parametrize(
    ("status_code", "body", "expected"),
    [
        (404, NO_ACTIVE_DEVICE_BODY, True),
        (404, NOT_FOUND_BODY, False),
        (403, json.dumps({"error": {"status": 403, "message": "Premium required", "reason": "PREMIUM_REQUIRED"}}), False),
    ],
)
def test_client_error_flags_only_the_no_active_device_404(
    monkeypatch: pytest.MonkeyPatch, status_code: int, body: str, expected: bool
) -> None:
    monkeypatch.setattr(
        spotify_mod,
        "resolve_spotify_runtime_credentials",
        lambda **kwargs: {"access_token": "t", "base_url": "https://api.spotify.com/v1"},
    )
    monkeypatch.setattr(spotify_mod.httpx, "request", lambda *a, **kw: _FakeResponse(status_code, body))

    with pytest.raises(spotify_mod.SpotifyAPIError) as exc:
        spotify_mod.SpotifyClient().start_playback(uris=[TRACK])

    assert exc.value.is_no_active_device is expected


# ── play falls back to an available device ─────────────────────────────────


def test_play_without_active_device_plays_on_an_available_device(monkeypatch, spawned) -> None:
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[TV, RESTRICTED_PHONE, PHONE]])
    _use(monkeypatch, stub)

    payload = _play(stub, uris=[TRACK])

    assert payload["success"] is True
    assert not payload.get("pending")
    assert "Pranav's iPhone" in json.dumps(payload)
    assert len(stub.play_calls) == 2
    retry = stub.play_calls[1]
    assert retry["device_id"] == "phone-1"
    assert retry["uris"] == [TRACK]
    assert spawned == []


def test_play_falls_back_to_any_device_when_no_smartphone(monkeypatch, spawned) -> None:
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[TV]])
    _use(monkeypatch, stub)

    payload = _play(stub, context_uri="spotify:album:1ATL5GLyefJaxhQzSPVrLX")

    assert payload["success"] is True
    assert stub.play_calls[1]["device_id"] == "tv-1"
    assert stub.play_calls[1]["context_uri"] == "spotify:album:1ATL5GLyefJaxhQzSPVrLX"


# ── no devices at all: pending play ────────────────────────────────────────


def test_play_without_any_device_returns_pending_then_plays_when_device_appears(monkeypatch, spawned) -> None:
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[], [], [PHONE]])
    _use(monkeypatch, stub)

    payload = _play(stub, uris=[TRACK], position_ms=1000)

    assert "error" not in payload
    assert payload["success"] is True
    assert payload["pending"] is True
    assert "open_app spotify" in payload["note"]
    assert len(spawned) == 1
    assert len(stub.play_calls) == 1  # nothing played yet

    pending, poll_client = spawned[0]
    clock = _FakeClock()
    outcome = spotify_tool._run_pending_play(pending, poll_client, sleep=clock.sleep, clock=clock)

    assert outcome == "played"
    assert len(stub.play_calls) == 2
    played = stub.play_calls[1]
    assert played["device_id"] == "phone-1"
    assert played["uris"] == [TRACK]
    assert played["position_ms"] == 1000
    assert spotify_tool._current_pending_play() is None


def test_pending_play_keeps_trying_when_the_new_device_is_not_ready_yet(monkeypatch, spawned) -> None:
    stub = _PlayerStub(play_errors=[_no_active_device(), _no_active_device()], device_polls=[[], [PHONE]])
    _use(monkeypatch, stub)
    _play(stub, uris=[TRACK])

    pending, poll_client = spawned[0]
    clock = _FakeClock()
    outcome = spotify_tool._run_pending_play(pending, poll_client, sleep=clock.sleep, clock=clock)

    assert outcome == "played"
    assert [c.get("device_id") for c in stub.play_calls] == [None, "phone-1", "phone-1"]


def test_newer_play_replaces_the_pending_one_and_old_song_never_plays(monkeypatch, spawned) -> None:
    stub = _PlayerStub(play_errors=[_no_active_device(), _no_active_device()], device_polls=[[]])
    _use(monkeypatch, stub)

    _play(stub, uris=[TRACK])
    _play(stub, uris=[OTHER_TRACK])
    assert len(spawned) == 2
    (old, old_client), (new, new_client) = spawned

    stub.device_polls = [[PHONE]]  # Spotify comes up
    clock = _FakeClock()
    assert spotify_tool._run_pending_play(old, old_client, sleep=clock.sleep, clock=clock) == "cancelled"
    assert spotify_tool._run_pending_play(new, new_client, sleep=clock.sleep, clock=clock) == "played"

    played_uris = [c["uris"] for c in stub.play_calls if c.get("device_id")]
    assert played_uris == [[OTHER_TRACK]]


def test_newer_play_arriving_mid_poll_stops_the_old_poller(monkeypatch, spawned) -> None:
    stub = _PlayerStub(play_errors=[_no_active_device(), _no_active_device()], device_polls=[[]])
    _use(monkeypatch, stub)
    _play(stub, uris=[TRACK])
    old, old_client = spawned[0]

    clock = _FakeClock()

    def sleep_then_new_request(seconds: float) -> None:
        clock.sleep(seconds)
        if clock.sleeps == 2:  # after one empty poll
            _play(stub, uris=[OTHER_TRACK])  # still no device → becomes the pending play
            stub.device_polls = [[PHONE]]  # ...and Spotify comes up right after

    outcome = spotify_tool._run_pending_play(old, old_client, sleep=sleep_then_new_request, clock=clock)

    assert outcome == "cancelled"
    assert all(c["uris"] != [TRACK] for c in stub.play_calls if c.get("device_id"))
    new, new_client = spawned[1]
    assert spotify_tool._run_pending_play(new, new_client, sleep=clock.sleep, clock=clock) == "played"
    assert stub.play_calls[-1]["uris"] == [OTHER_TRACK]


def test_a_play_that_succeeds_directly_cancels_the_older_pending_play(monkeypatch, spawned) -> None:
    stub = _PlayerStub(play_errors=[_no_active_device(), None], device_polls=[[]])
    _use(monkeypatch, stub)

    _play(stub, uris=[TRACK])
    payload = _play(stub, uris=[OTHER_TRACK])  # Spotify is up by now
    assert payload["success"] is True and not payload.get("pending")

    old, old_client = spawned[0]
    stub.device_polls = [[PHONE]]
    clock = _FakeClock()
    assert spotify_tool._run_pending_play(old, old_client, sleep=clock.sleep, clock=clock) == "cancelled"
    assert [c["uris"] for c in stub.play_calls] == [[TRACK], [OTHER_TRACK]]


def test_pending_play_gives_up_after_the_window(monkeypatch, spawned, caplog) -> None:
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[]])
    _use(monkeypatch, stub)
    _play(stub, uris=[TRACK])
    pending, poll_client = spawned[0]

    clock = _FakeClock()
    with caplog.at_level(logging.INFO, logger=spotify_tool.logger.name):
        outcome = spotify_tool._run_pending_play(pending, poll_client, sleep=clock.sleep, clock=clock)

    assert outcome == "timeout"
    assert len(stub.play_calls) == 1  # only the original failed attempt
    assert clock.now >= spotify_tool._PENDING_PLAY_WINDOW_S
    assert clock.now < spotify_tool._PENDING_PLAY_WINDOW_S + 2 * spotify_tool._PENDING_PLAY_POLL_INTERVAL_S
    assert spotify_tool._current_pending_play() is None
    assert any("gave up" in r.getMessage() for r in caplog.records)


def test_pending_poller_thread_plays_and_exits(monkeypatch) -> None:
    """The real background thread: plays once a device appears, then stops."""
    monkeypatch.setattr(spotify_tool, "_PENDING_PLAY_POLL_INTERVAL_S", 0.01)
    threads: list = []
    original_spawn = spotify_tool._spawn_pending_play_poller

    def spawn_and_record(pending, client):
        thread = original_spawn(pending, client)
        threads.append(thread)
        return thread

    monkeypatch.setattr(spotify_tool, "_spawn_pending_play_poller", spawn_and_record)
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[], [], [PHONE]])
    _use(monkeypatch, stub)

    payload = _play(stub, uris=[TRACK])
    assert payload["pending"] is True
    assert len(threads) == 1
    threads[0].join(timeout=5)

    assert not threads[0].is_alive()
    assert threads[0].daemon
    assert stub.play_calls[-1]["device_id"] == "phone-1"
    assert stub.play_calls[-1]["uris"] == [TRACK]


# ── everything else unchanged ──────────────────────────────────────────────


def test_other_404_on_play_still_returns_the_error(monkeypatch, spawned) -> None:
    stub = _PlayerStub(play_errors=[_api_error(404, NOT_FOUND_BODY)], device_polls=[[PHONE]])
    _use(monkeypatch, stub)

    payload = _play(stub, uris=[TRACK])

    assert "error" in payload
    assert not payload.get("pending")
    assert stub.device_calls == 0
    assert len(stub.play_calls) == 1
    assert spawned == []


def test_pause_cancels_a_pending_play(monkeypatch, spawned) -> None:
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[]])
    _use(monkeypatch, stub)
    _play(stub, uris=[TRACK])
    pending, poll_client = spawned[0]

    spotify_tool._handle_spotify_playback({"action": "pause"})
    stub.device_polls = [[PHONE]]
    clock = _FakeClock()

    assert spotify_tool._run_pending_play(pending, poll_client, sleep=clock.sleep, clock=clock) == "cancelled"
    assert len(stub.play_calls) == 1


def test_pause_without_active_device_keeps_todays_error(monkeypatch, spawned) -> None:
    stub = _PlayerStub(device_polls=[[PHONE]])
    _use(monkeypatch, stub)

    payload = json.loads(spotify_tool._handle_spotify_playback({"action": "pause"}))

    assert "error" in payload
    assert stub.device_calls == 0
    assert spawned == []


# ── phone turns (CarPlay): open the song on the phone, never the MacBook ────
#
# In the car (2026-10-18) iPhone Spotify opened on CarPlay and idle never showed
# up as a Spotify Connect device, so waiting for one couldn't work — and the
# only device listed was his MacBook at home. A phone turn now asks the phone to
# open the song's own spotify: link (open_url, now=true — Spotify opens and
# plays it), then makes sure in the background that the phone plays exactly
# that. Turns from the web or the Mac keep today's device choice.

import sys  # noqa: E402
from pathlib import Path  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))

from tools import car_app_followup  # noqa: E402

PLAYLIST = "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"
MACBOOK = {"id": "mac-1", "name": "Pranav's MacBook Pro", "type": "Computer", "is_restricted": False, "is_active": False}
PHONE_ACTIVE = {**PHONE, "is_active": True}
DEVICE_NOT_FOUND_BODY = json.dumps({"error": {"status": 404, "message": "Device not found"}})
OPENED = {"ok": True, "result": {"opened": True}}
NO_OPEN_URL = {"ok": False, "error": "that device has no open_url skill"}
APP_OPENING = {"ok": True, "result": {"launched": True, "note": "It opens on the car's screen when you finish speaking."}}


def _playing(uri: str, *, device: str = "phone-1", context: str | None = None, is_playing: bool = True) -> dict:
    return {
        "is_playing": is_playing,
        "device": {"id": device},
        "item": {"uri": uri},
        "context": {"uri": context} if context else None,
    }


class _Phone:
    """The turn's device: records skill calls, answers per skill."""

    def __init__(self):
        self.calls: list = []
        self.replies = {"open_url": OPENED, "open_app": APP_OPENING}

    def __call__(self, device_id, skill, args, timeout=None):
        self.calls.append((device_id, skill, dict(args)))
        return self.replies.get(skill, {"ok": False, "error": f"no {skill} skill"})


def _turn(monkeypatch, *, kind="mobile-ios", carplay=True):
    """A turn from ``kind`` (session "sess-car"); skill calls and follow-up
    threads are captured instead of sent / started."""
    from api import turn_origin

    phone = _Phone()
    runs: list = []
    monkeypatch.setattr(car_app_followup, "_invoke_device_skill", phone)
    monkeypatch.setattr(car_app_followup, "start_background", lambda run, name: runs.append(run))
    turn_origin.note_turn("sess-car", {"device_id": "iphone-1", "name": "iPhone", "kind": kind}, carplay=carplay)
    return phone, runs


@pytest.fixture
def car_turn(monkeypatch: pytest.MonkeyPatch):
    from api import turn_origin

    yield _turn(monkeypatch)
    turn_origin.note_turn("sess-car", None)


@pytest.fixture
def web_turn(monkeypatch: pytest.MonkeyPatch):
    from api import turn_origin

    yield _turn(monkeypatch, kind="browser", carplay=False)
    turn_origin.note_turn("sess-car", None)


def _car_play(**args) -> dict:
    return json.loads(spotify_tool._handle_spotify_playback({"action": "play", **args}, task_id="sess-car"))


def _run(runs, i=0) -> str:
    clock = _FakeClock()
    return runs[i](sleep=clock.sleep, clock=clock)


def test_a_phone_turn_opens_the_song_on_the_phone_now_and_returns_at_once(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[MACBOOK]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK])

    assert phone.calls == [("iphone-1", "open_url", {"url": TRACK, "now": True})]
    assert payload["success"] is True and payload["pending"] is True
    assert "Playing it in Spotify on the car" in payload["note"]
    assert len(stub.play_calls) == 1  # only the failed attempt: not on the MacBook
    assert len(runs) == 1 and spawned == []


def test_a_phone_turn_opens_a_playlist_by_its_context_uri(monkeypatch, spawned, car_turn) -> None:
    phone, _ = car_turn
    _use(monkeypatch, _PlayerStub(play_errors=[_no_active_device()], device_polls=[[]]))

    _car_play(context_uri=PLAYLIST)

    assert phone.calls == [("iphone-1", "open_url", {"url": PLAYLIST, "now": True})]


def test_a_phone_turn_never_plays_on_a_computer(monkeypatch, spawned, car_turn) -> None:
    _, runs = car_turn
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[MACBOOK, {**MACBOOK, "is_active": True}]])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK])
    outcome = _run(runs)  # the MacBook is all there ever is

    assert outcome == "timeout"
    assert all(c.get("device_id") != "mac-1" for c in stub.play_calls)
    assert spotify_tool._current_pending_play() is None


def test_the_phone_is_started_on_the_song_when_it_shows_up_on_another_track(monkeypatch, spawned, car_turn) -> None:
    _, runs = car_turn
    stub = _PlayerStub(
        play_errors=[_no_active_device()],
        device_polls=[[MACBOOK], [MACBOOK], [MACBOOK, PHONE_ACTIVE]],
        playback_states=[_playing(OTHER_TRACK), _playing(TRACK)],
    )
    _use(monkeypatch, stub)
    _car_play(uris=[TRACK], position_ms=1000)

    assert _run(runs) == "done"
    assert stub.play_calls[-1] == {"device_id": "phone-1", "context_uri": None, "uris": [TRACK],
                                   "offset": None, "position_ms": 1000}
    assert spotify_tool._current_pending_play() is None


def test_nothing_is_restarted_when_the_phone_already_plays_the_song(monkeypatch, spawned, car_turn) -> None:
    _, runs = car_turn
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[MACBOOK], [MACBOOK, PHONE_ACTIVE]],
                       playback_states=[_playing(TRACK)])
    _use(monkeypatch, stub)
    _car_play(uris=[TRACK])

    assert _run(runs) == "done"
    assert len(stub.play_calls) == 1  # just the original failed attempt


def test_nothing_is_restarted_when_the_phone_already_plays_the_playlist(monkeypatch, spawned, car_turn) -> None:
    _, runs = car_turn
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[], [PHONE_ACTIVE]],
                       playback_states=[_playing(TRACK, context=PLAYLIST)])
    _use(monkeypatch, stub)
    _car_play(context_uri=PLAYLIST)

    assert _run(runs) == "done"
    assert len(stub.play_calls) == 1


def test_a_404_on_an_explicit_device_takes_the_same_path(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(play_errors=[_api_error(404, DEVICE_NOT_FOUND_BODY)], device_polls=[[MACBOOK]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK], device_id="72332cff")

    assert "error" not in payload
    assert phone.calls == [("iphone-1", "open_url", {"url": TRACK, "now": True})]
    assert len(runs) == 1


def test_a_listed_phone_is_played_on_directly(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[MACBOOK, PHONE]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK])

    assert stub.play_calls[-1]["device_id"] == "phone-1"
    assert "Pranav's iPhone" in payload["note"]
    assert phone.calls == [] and runs == []


def test_a_listed_phone_that_404s_is_opened_instead(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(play_errors=[_no_active_device(), _api_error(404, DEVICE_NOT_FOUND_BODY)],
                       device_polls=[[PHONE]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK])

    assert payload["pending"] is True
    assert phone.calls == [("iphone-1", "open_url", {"url": TRACK, "now": True})]
    assert len(runs) == 1


def test_newest_play_wins_while_the_phone_opens_the_song(monkeypatch, spawned, car_turn) -> None:
    _, runs = car_turn
    stub = _PlayerStub(play_errors=[_no_active_device(), _no_active_device()], device_polls=[[]])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK])
    _car_play(uris=[OTHER_TRACK])
    stub.device_polls = [[PHONE_ACTIVE]]

    assert _run(runs, 0) == "cancelled"
    assert _run(runs, 1) == "done"
    assert [c["uris"] for c in stub.play_calls if c.get("device_id")] == [[OTHER_TRACK]]


def test_pause_cancels_the_song_the_phone_is_opening(monkeypatch, spawned, car_turn) -> None:
    _, runs = car_turn
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[]])
    _use(monkeypatch, stub)
    _car_play(uris=[TRACK])

    spotify_tool._handle_spotify_playback({"action": "pause"}, task_id="sess-car")
    stub.device_polls = [[PHONE_ACTIVE]]

    assert _run(runs) == "cancelled"
    assert len(stub.play_calls) == 1


def test_a_phone_turn_out_of_the_car_says_the_phone(monkeypatch, spawned) -> None:
    from api import turn_origin

    _turn(monkeypatch, carplay=False)
    try:
        _use(monkeypatch, _PlayerStub(play_errors=[_no_active_device()], device_polls=[[]]))
        payload = _car_play(uris=[TRACK])
    finally:
        turn_origin.note_turn("sess-car", None)

    assert "Playing it in Spotify on his phone" in payload["note"]


# ── a phone without open_url: open the app, then the pending play ──────────


def test_a_phone_without_open_url_opens_spotify_and_waits_for_the_phone(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    phone.replies["open_url"] = NO_OPEN_URL
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[MACBOOK], [MACBOOK, PHONE]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK])

    assert [c[1] for c in phone.calls] == ["open_url", "open_app"]
    assert "Opening Spotify" in payload["note"]
    assert "opens on the car's screen" in payload["note"]
    assert "open_app spotify" not in payload["note"]
    assert spawned == [] and len(runs) == 1

    assert _run(runs) == "done"
    assert stub.play_calls[-1]["device_id"] == "phone-1"
    assert all(c.get("device_id") != "mac-1" for c in stub.play_calls)


def test_a_phone_that_cannot_open_spotify_at_all_falls_back_to_asking_the_model(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    phone.replies = {}
    _use(monkeypatch, _PlayerStub(play_errors=[_no_active_device()], device_polls=[[]]))

    payload = _car_play(uris=[TRACK])

    assert payload["pending"] is True
    assert "open_app spotify" in payload["note"]
    assert len(runs) == 1  # still waits for Spotify to come up


def test_resuming_with_nothing_to_open_opens_the_app(monkeypatch, spawned, car_turn) -> None:
    phone, _ = car_turn
    _use(monkeypatch, _PlayerStub(play_errors=[_no_active_device()], device_polls=[[]]))

    _car_play()  # "resume": no track, no playlist

    assert [c[1] for c in phone.calls] == ["open_app"]


# ── turns from the web / the Mac / nowhere: today's choice ──────────────────


def test_a_web_turn_still_plays_on_the_listed_computer(monkeypatch, spawned, web_turn) -> None:
    phone, runs = web_turn
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[MACBOOK]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK])

    assert stub.play_calls[-1]["device_id"] == "mac-1"
    assert "MacBook" in payload["note"]
    assert phone.calls == [] and runs == []


def test_a_web_turn_keeps_the_error_for_a_missing_explicit_device(monkeypatch, spawned, web_turn) -> None:
    phone, runs = web_turn
    stub = _PlayerStub(play_errors=[_api_error(404, DEVICE_NOT_FOUND_BODY)], device_polls=[[MACBOOK]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK], device_id="72332cff")

    assert "error" in payload
    assert phone.calls == [] and runs == [] and len(stub.play_calls) == 1


def test_a_turn_from_an_unknown_device_keeps_todays_note(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[]])
    _use(monkeypatch, stub)

    payload = json.loads(spotify_tool._handle_spotify_playback(
        {"action": "play", "uris": [TRACK]}, task_id="some-telegram-chat"))

    assert phone.calls == []
    assert "open_app spotify" in payload["note"]
    assert len(spawned) == 1 and runs == []


def test_a_play_the_phone_took_but_did_not_start_is_sent_again(monkeypatch, spawned, car_turn) -> None:
    # 2026-10-18 06:49: the phone's Spotify came up and took the play 2 s after the
    # song opened on CarPlay — "started", said the log — and nothing played.
    _, runs = car_turn
    stub = _PlayerStub(
        play_errors=[_no_active_device()],
        device_polls=[[MACBOOK], [MACBOOK, PHONE_ACTIVE]],
        playback_states=[{"empty": True}] * 5 + [_playing(TRACK)],
    )
    _use(monkeypatch, stub)
    _car_play(uris=[TRACK])

    assert _run(runs) == "done"
    phone_plays = [c for c in stub.play_calls if c.get("device_id") == "phone-1"]
    assert len(phone_plays) == 2, "sent again until Spotify says it's playing"


def _phone_plays(stub) -> list[dict]:
    return [c for c in stub.play_calls if c.get("device_id") == "phone-1"]


def test_a_taken_play_is_not_restarted_while_it_loads(monkeypatch, spawned, car_turn) -> None:
    # 2026-10-18 16:02: the play went to the phone again every check (15 in 30 s) —
    # each one restarts the song, so one that needs a few seconds to load never does.
    _, runs = car_turn
    stub = _PlayerStub(
        play_errors=[_no_active_device()],
        device_polls=[[MACBOOK], [MACBOOK, PHONE_ACTIVE]],
        playback_states=[{"empty": True}, {"empty": True}, {"empty": True}, _playing(TRACK)],
    )
    _use(monkeypatch, stub)
    _car_play(uris=[TRACK])

    assert _run(runs) == "done"
    assert len(_phone_plays(stub)) == 1


def test_a_song_the_phone_holds_paused_is_resumed_not_restarted(monkeypatch, spawned, car_turn) -> None:
    _, runs = car_turn
    stub = _PlayerStub(
        play_errors=[_no_active_device()],
        device_polls=[[MACBOOK], [MACBOOK, PHONE_ACTIVE]],
        playback_states=[{"empty": True}, _playing(TRACK, is_playing=False), _playing(TRACK)],
    )
    _use(monkeypatch, stub)
    _car_play(uris=[TRACK])

    assert _run(runs) == "done"
    first, resume = _phone_plays(stub)
    assert first.get("uris") == [TRACK]
    assert resume == {"device_id": "phone-1"}, "a resume, not the song from the top"


def test_a_relinked_song_counts_as_playing(monkeypatch, spawned, car_turn) -> None:
    # Spotify may play its own copy of a track for his country: the item is another
    # uri, and `linked_from` is the one asked for.
    _, runs = car_turn
    relinked = _playing("spotify:track:0000000000000000000000")
    relinked["item"]["linked_from"] = {"uri": TRACK}
    stub = _PlayerStub(
        play_errors=[_no_active_device()],
        device_polls=[[MACBOOK], [MACBOOK, PHONE_ACTIVE]],
        playback_states=[{"empty": True}, relinked],
    )
    _use(monkeypatch, stub)
    _car_play(uris=[TRACK])

    assert _run(runs) == "done"
    assert len(_phone_plays(stub)) == 1


def test_each_check_logs_what_spotify_reports(monkeypatch, spawned, car_turn, caplog) -> None:
    _, runs = car_turn
    stub = _PlayerStub(
        play_errors=[_no_active_device()],
        device_polls=[[MACBOOK], [MACBOOK, PHONE_ACTIVE]],
        playback_states=[_playing(TRACK, device="mac-1", is_playing=False), _playing(TRACK)],
    )
    _use(monkeypatch, stub)
    _car_play(uris=[TRACK])

    with caplog.at_level(logging.INFO, logger=spotify_tool.logger.name):
        assert _run(runs) == "done"
    checks = [r.getMessage() for r in caplog.records if "Spotify reports" in r.getMessage()]
    assert checks and "mac-1" in checks[0] and "paused" in checks[0] and TRACK in checks[0]


def test_a_song_that_never_starts_is_reported_not_done(monkeypatch, spawned, car_turn, caplog) -> None:
    _, runs = car_turn
    stub = _PlayerStub(
        play_errors=[_no_active_device()],
        device_polls=[[MACBOOK], [MACBOOK, PHONE_ACTIVE]],
        playback_states=[{"empty": True}],
    )
    _use(monkeypatch, stub)
    _car_play(uris=[TRACK])

    assert _run(runs) == "timeout"
    assert spotify_tool._current_pending_play() is None


def test_a_play_that_never_reaches_the_phone_moves_playback_there_first(monkeypatch, spawned, car_turn) -> None:
    # 2026-10-18 16:56 and 17:03: the phone took three plays and Spotify said "nothing
    # playing anywhere" every check — the play never reached its player. The resend
    # transfers playback to the phone (which wakes its player) before playing again.
    _, runs = car_turn
    stub = _PlayerStub(
        play_errors=[_no_active_device()],
        device_polls=[[MACBOOK], [MACBOOK, PHONE_ACTIVE]],
        playback_states=[{"empty": True}] * 5 + [_playing(TRACK)],
    )
    _use(monkeypatch, stub)
    _car_play(uris=[TRACK])

    assert _run(runs) == "done"
    assert stub.transfer_calls == [{"device_id": "phone-1", "play": True}]
    assert len(_phone_plays(stub)) == 2
