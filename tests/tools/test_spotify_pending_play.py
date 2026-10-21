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
        self.resume_calls: list[dict] = []
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

    remote = None  # what app_remote_credentials() gives: None until he signs in with app-remote-control

    def app_remote_credentials(self):
        return self.remote

    def resume_playback(self, **kw):
        self.resume_calls.append(kw)
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
        "device": {"id": device, "name": "iPhone" if device.startswith("phone") else "MacBook Pro",
                   "type": "Smartphone" if device.startswith("phone") else "Computer"},
        "item": {"uri": uri},
        "context": {"uri": context} if context else None,
    }


class _Phone:
    """The turn's device: records skill calls, answers per skill. A skill only the server may
    run is refused, as the webui's HTTP route does (2026-10-20 22:44)."""

    def __init__(self):
        self.calls: list = []
        self.replies = {"open_url": OPENED, "open_app": APP_OPENING,
                        "spotify_remote_play": {"ok": False,
                                                "error": "'spotify_remote_play' is only run by the server itself"}}

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


def test_a_404_on_an_explicit_device_takes_the_same_path(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(play_errors=[_api_error(404, DEVICE_NOT_FOUND_BODY)], device_polls=[[MACBOOK]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK], device_id="72332cff")

    assert "error" not in payload
    assert phone.calls == [("iphone-1", "open_url", {"url": TRACK, "now": True})]
    assert len(runs) == 1


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


def test_a_web_turn_whose_named_device_is_gone_plays_on_a_listed_one(monkeypatch, spawned, web_turn) -> None:
    # The model reuses a device id from an earlier turn (2026-10-20 23:06: the car's iPhone id
    # on a turn from the Mac): it 404s, and the song plays on a device Spotify lists.
    phone, runs = web_turn
    stub = _PlayerStub(play_errors=[_api_error(404, DEVICE_NOT_FOUND_BODY)], device_polls=[[MACBOOK]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK], device_id="72332cff")

    assert "error" not in payload
    assert stub.play_calls[-1]["device_id"] == "mac-1"
    assert phone.calls == [] and runs == []


def test_a_turn_from_nowhere_keeps_the_error_for_a_missing_named_device(monkeypatch, spawned) -> None:
    stub = _PlayerStub(play_errors=[_api_error(404, DEVICE_NOT_FOUND_BODY)], device_polls=[[MACBOOK]])
    _use(monkeypatch, stub)

    payload = json.loads(spotify_tool._handle_spotify_playback(
        {"action": "play", "uris": [TRACK], "device_id": "72332cff"}, task_id="some-telegram-chat"))

    assert "error" in payload and len(stub.play_calls) == 1


@pytest.fixture
def mac_turn(monkeypatch: pytest.MonkeyPatch):
    from api import turn_origin

    yield _turn(monkeypatch, kind="desktop", carplay=False)
    turn_origin.note_turn("sess-car", None)


def test_a_mac_turn_with_spotify_closed_opens_it_on_the_mac_and_plays_there(monkeypatch, spawned, mac_turn) -> None:
    # 2026-10-20 23:17: Spotify closed on the Mac — the open was refused ("unexpected args:
    # ['app']"), nothing opened, and the play gave up after 30 s.
    from api import device_bridge

    phone, runs = mac_turn
    monkeypatch.setattr(device_bridge, "skills_for_device", lambda device_id: [{"name": "open_app", "input_schema": {
        "type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}}])
    phone.replies["open_app"] = {"ok": True, "result": {"ok": True, "name": "Spotify"}}
    stub = _PlayerStub(device_polls=[[], [], [PHONE, MACBOOK]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK])

    assert phone.calls == [("iphone-1", "open_app", {"name": "Spotify"})]
    assert "Opening Spotify" in payload["note"]
    assert _run(runs) == "done"
    assert stub.play_calls[-1]["device_id"] == "mac-1"


def test_a_mac_turn_naming_no_device_plays_on_the_mac_not_the_active_phone(monkeypatch, spawned, mac_turn) -> None:
    # 2026-10-20 23:34: "play Blinding Lights on Spotify" from the Mac, no device named —
    # Spotify sent it to the iPhone still active from the car (HTTP 204), nothing played.
    phone, runs = mac_turn
    stub = _PlayerStub(device_polls=[[PHONE_ACTIVE, MACBOOK]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK])

    assert payload["success"] is True
    assert [c.get("device_id") for c in stub.play_calls] == ["mac-1"]
    assert phone.calls == [] and runs == []


def test_a_mac_turn_with_spotify_closed_there_opens_it_even_with_the_phone_active(monkeypatch, spawned, mac_turn) -> None:
    from api import device_bridge

    phone, runs = mac_turn
    monkeypatch.setattr(device_bridge, "skills_for_device", lambda device_id: [{"name": "open_app", "input_schema": {
        "type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}}])
    phone.replies["open_app"] = {"ok": True, "result": {"ok": True, "name": "Spotify"}}
    stub = _PlayerStub(device_polls=[[PHONE_ACTIVE], [PHONE_ACTIVE], [PHONE_ACTIVE, MACBOOK]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK])

    assert payload["pending"] is True
    assert stub.play_calls == []  # never sent to the phone
    assert phone.calls == [("iphone-1", "open_app", {"name": "Spotify"})]
    assert _run(runs) == "done"
    assert [c.get("device_id") for c in stub.play_calls] == ["mac-1"]


MAC_PLAYED = {"ok": True, "result": {"ok": True, "playing": True, "uri": TRACK, "track": "Blinding Lights"}}


@pytest.fixture
def mac_spotify_app(monkeypatch: pytest.MonkeyPatch):
    """The Mac client offers spotify_play (its Spotify app, over AppleScript)."""
    from api import device_bridge

    monkeypatch.setattr(device_bridge, "skills_for_device",
                        lambda device_id: [{"name": "spotify_play"}, {"name": "open_app"}])


def test_a_mac_turn_has_the_mac_spotify_app_play_it(monkeypatch, spawned, mac_turn, mac_spotify_app) -> None:
    # 23:34 and 23:37: the Web API sent it to the iPhone; the computer-use fallback opened
    # Spotify's search and typed nothing — and Jarvis said it was playing.
    phone, runs = mac_turn
    phone.replies["spotify_play"] = MAC_PLAYED
    stub = _PlayerStub(device_polls=[[PHONE_ACTIVE]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK], device_id="72332cff")

    assert payload["success"] is True and "Blinding Lights" in payload["note"]
    assert phone.calls == [("iphone-1", "spotify_play", {"uri": TRACK})]
    assert stub.play_calls == [] and runs == []


def test_a_mac_spotify_that_took_it_but_isnt_playing_is_not_reported_playing(monkeypatch, spawned, mac_turn,
                                                                              mac_spotify_app) -> None:
    phone, _ = mac_turn
    phone.replies["spotify_play"] = {"ok": True, "result": {"ok": True, "playing": False, "uri": TRACK,
                                                           "note": "Spotify took it but isn't playing (paused)"}}
    _use(monkeypatch, _PlayerStub(device_polls=[[]]))

    payload = _car_play(uris=[TRACK])

    assert payload["success"] is False and "isn't playing" in payload["note"]


def test_a_mac_spotify_app_that_refuses_says_why(monkeypatch, spawned, mac_turn, mac_spotify_app) -> None:
    phone, _ = mac_turn
    phone.replies["spotify_play"] = {"ok": False, "error": "macOS hasn't allowed Jarvis to control Spotify: …"}
    _use(monkeypatch, _PlayerStub(device_polls=[[]]))

    payload = _car_play(uris=[TRACK])

    assert "control Spotify" in payload["error"]


def test_a_mac_turn_asking_for_a_listed_device_plays_there(monkeypatch, spawned, mac_turn) -> None:
    _, runs = mac_turn
    stub = _PlayerStub(device_polls=[[TV, MACBOOK]])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK], device_id="tv-1")

    assert [c.get("device_id") for c in stub.play_calls] == ["tv-1"]


def test_a_mac_turn_plays_on_the_mac_not_the_phone(monkeypatch, spawned, mac_turn) -> None:
    # 2026-10-20 23:06: "Play Blinding Lights on Spotify" from the Mac, Spotify open there —
    # the car's iPhone id 404'd and Jarvis gave up ("no device is active").
    phone, runs = mac_turn
    stub = _PlayerStub(device_polls=[[PHONE, MACBOOK]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK], device_id="72332cff")

    assert "error" not in payload
    assert [c.get("device_id") for c in stub.play_calls] == ["mac-1"]  # the stale id is never tried
    assert "MacBook" in payload["device"]["name"]
    assert phone.calls == [] and runs == []


def test_a_turn_from_an_unknown_device_keeps_todays_note(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(play_errors=[_no_active_device()], device_polls=[[]])
    _use(monkeypatch, stub)

    payload = json.loads(spotify_tool._handle_spotify_playback(
        {"action": "play", "uris": [TRACK]}, task_id="some-telegram-chat"))

    assert phone.calls == []
    assert "open_app spotify" in payload["note"]
    assert len(spawned) == 1 and runs == []




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


REMOTE = {"token": "tok-123", "client_id": "cid-9"}
REMOTE_PLAYED = {"ok": True, "result": {"played": TRACK}}


@pytest.fixture
def bridge(monkeypatch: pytest.MonkeyPatch):
    """The webui's own device bridge — the only way the server runs a skill only it may run.
    ``answers[skill]`` is one reply, or a list answered in turn."""
    from api import device_bridge

    calls: list = []
    answers: dict = {"spotify_remote_play": REMOTE_PLAYED}

    def invoke(device_id, skill, args, timeout=None):
        calls.append((device_id, skill, dict(args)))
        answer = answers.get(skill, {"ok": False, "error": f"no {skill} skill"})
        if isinstance(answer, list):
            return answer.pop(0) if len(answer) > 1 else answer[0]
        return answer

    monkeypatch.setattr(device_bridge, "invoke_skill", invoke)
    return calls, answers


def _remote_plays(calls) -> list:
    return [c for c in calls if c[1] == "spotify_remote_play"]


def _app_remote_stub(**kw) -> _PlayerStub:
    stub = _PlayerStub(**kw)
    stub.remote = dict(REMOTE)
    return stub


def test_a_phone_turn_asking_for_the_macbook_plays_there(monkeypatch, spawned, car_turn, bridge) -> None:
    phone, runs = car_turn
    calls, _ = bridge
    stub = _app_remote_stub(device_polls=[[MACBOOK, PHONE]])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK], device_id="mac-1")

    assert payload["success"] is True
    assert stub.play_calls[-1]["device_id"] == "mac-1"
    assert phone.calls == [] and runs == [] and _remote_plays(calls) == []


def test_without_the_permission_the_phone_is_not_asked(monkeypatch, spawned, car_turn, bridge) -> None:
    phone, runs = car_turn
    calls, _ = bridge
    _use(monkeypatch, _PlayerStub(play_errors=[_no_active_device()], device_polls=[[MACBOOK]]))
    _car_play(uris=[TRACK])
    assert len(runs) == 1
    _run(runs)
    assert _remote_plays(calls) == [] and all(c[1] != "spotify_remote_play" for c in phone.calls)


# ── a phone turn: the song's link opens on the phone; never a Web API play naming it ──
# Tested live 2026-10-21 00:10-00:14, Spotify up in CarPlay: a link Spotify is opened on
# plays; a play with no body (resume) starts what it holds; a Web API play naming a song
# answers 204 and drops the player to "None at 0 ms" — Jarvis's own play stopped the songs.


def _opens(phone) -> list:
    return [c for c in phone.calls if c[1] == "open_url"]


def test_a_phone_turn_opens_the_song_and_never_names_it_in_a_web_api_play(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(device_polls=[[PHONE]], playback_states=[{"empty": True}, {"empty": True}, _playing(TRACK)])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK])

    assert payload["pending"] is True and "Playing it in Spotify on the car" in payload["note"]
    assert _opens(phone) == [("iphone-1", "open_url", {"url": TRACK, "now": True})]
    assert len(runs) == 1 and spawned == []
    assert _run(runs) == "played"
    assert stub.play_calls == [] and stub.transfer_calls == []
    assert spotify_tool._current_pending_play() is None


def test_a_listed_phone_is_never_sent_a_web_api_play(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(device_polls=[[MACBOOK, PHONE_ACTIVE]], playback_states=[{"empty": True}, _playing(TRACK)])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK])

    assert _run(runs) == "played"
    assert stub.play_calls == [] and len(_opens(phone)) == 1


def test_a_song_the_phone_holds_paused_is_resumed_with_no_song_named(monkeypatch, spawned, car_turn) -> None:
    _, runs = car_turn
    stub = _PlayerStub(playback_states=[{"empty": True}, _playing(TRACK, is_playing=False), _playing(TRACK)])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK])

    assert _run(runs) == "played"
    assert stub.resume_calls == [{"device_id": "phone-1"}]
    assert stub.play_calls == []


def test_a_phone_that_holds_nothing_gets_the_link_again(monkeypatch, spawned, car_turn) -> None:
    # 00:12: Spotify up on the car, the link opened again — and it played.
    phone, runs = car_turn
    stub = _PlayerStub(playback_states=[{"empty": True}] * 5 + [_playing(TRACK)])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK])

    assert _run(runs) == "played"
    assert len(_opens(phone)) >= 2
    assert stub.play_calls == []


def test_a_song_the_phone_already_plays_is_left_alone(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(playback_states=[_playing(TRACK)])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK])

    assert payload["success"] is True
    assert phone.calls == [] and runs == [] and stub.play_calls == []


def test_a_playlist_the_phone_already_plays_is_left_alone(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    _use(monkeypatch, _PlayerStub(playback_states=[_playing(TRACK, context=PLAYLIST)]))

    _car_play(context_uri=PLAYLIST)

    assert phone.calls == [] and runs == []


def test_a_relinked_song_counts_as_playing(monkeypatch, spawned, car_turn) -> None:
    # Spotify may play its own copy of a track for his country: `linked_from` is the asked one.
    phone, runs = car_turn
    relinked = _playing("spotify:track:0000000000000000000000")
    relinked["item"]["linked_from"] = {"uri": TRACK}
    _use(monkeypatch, _PlayerStub(playback_states=[{"empty": True}, relinked]))

    _car_play(uris=[TRACK])

    assert _run(runs) == "played"
    assert len(_opens(phone)) == 1


def test_another_song_playing_is_switched_by_the_phones_spotify_app(monkeypatch, spawned, car_turn, bridge) -> None:
    # App Remote takes a connection while Spotify plays; a link opened then only shows the song.
    phone, runs = car_turn
    calls, _ = bridge
    stub = _app_remote_stub(playback_states=[_playing(OTHER_TRACK), _playing(TRACK)])
    _use(monkeypatch, stub)

    payload = _car_play(uris=[TRACK])

    assert payload["success"] is True
    assert _remote_plays(calls) == [("iphone-1", "spotify_remote_play", {"uri": TRACK, **REMOTE})]
    assert phone.calls == []
    assert _run(runs) == "played"
    assert stub.play_calls == []


def test_without_the_spotify_app_a_playing_song_is_paused_then_the_link_opened(monkeypatch, spawned,
                                                                              car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(playback_states=[_playing(OTHER_TRACK), _playing(TRACK)])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK])

    assert stub.pause_calls == 1
    assert len(_opens(phone)) == 1
    assert _run(runs) == "played"
    assert stub.play_calls == []


def test_a_spotify_app_that_only_woke_doesnt_count_as_switched(monkeypatch, spawned, car_turn, bridge) -> None:
    phone, runs = car_turn
    _, answers = bridge
    answers["spotify_remote_play"] = {"ok": True, "result": {"woke": TRACK}}
    stub = _app_remote_stub(playback_states=[_playing(OTHER_TRACK), _playing(TRACK)])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK])

    assert stub.pause_calls == 1 and len(_opens(phone)) == 1


def test_each_check_logs_what_spotify_reports(monkeypatch, spawned, car_turn, caplog) -> None:
    _, runs = car_turn
    _use(monkeypatch, _PlayerStub(playback_states=[{"empty": True}, _playing(TRACK, device="mac-1", is_playing=False),
                                                   _playing(TRACK)]))
    _car_play(uris=[TRACK])

    with caplog.at_level(logging.INFO, logger=spotify_tool.logger.name):
        assert _run(runs) == "played"
    checks = [r.getMessage() for r in caplog.records if "Spotify reports for the play on the phone" in r.getMessage()]
    assert checks and "mac-1" in checks[0] and "paused" in checks[0] and TRACK in checks[0]


def test_a_song_that_never_plays_on_the_phone_gives_up(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(playback_states=[{"empty": True}])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK])

    assert _run(runs) == "timeout"
    assert spotify_tool._current_pending_play() is None
    assert stub.play_calls == []


def test_the_newest_play_wins_on_the_phone(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    _use(monkeypatch, _PlayerStub(playback_states=[{"empty": True}, {"empty": True}, _playing(OTHER_TRACK)]))

    _car_play(uris=[TRACK])
    _car_play(uris=[OTHER_TRACK])

    assert _run(runs, 0) == "cancelled"
    assert _run(runs, 1) == "played"
    assert [c[2]["url"] for c in _opens(phone)] == [TRACK, OTHER_TRACK]


def test_pause_cancels_the_song_the_phone_is_opening(monkeypatch, spawned, car_turn) -> None:
    _, runs = car_turn
    stub = _PlayerStub(playback_states=[{"empty": True}, _playing(TRACK, is_playing=False)])
    _use(monkeypatch, stub)
    _car_play(uris=[TRACK])

    spotify_tool._handle_spotify_playback({"action": "pause"}, task_id="sess-car")

    assert _run(runs) == "cancelled"
    assert stub.resume_calls == [] and stub.play_calls == []


def test_a_phone_without_open_url_opens_spotify_and_waits(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    phone.replies["open_url"] = NO_OPEN_URL
    _use(monkeypatch, _PlayerStub(play_errors=[_no_active_device()], device_polls=[[MACBOOK]]))

    payload = _car_play(uris=[TRACK])

    assert [c[1] for c in phone.calls][-1] == "open_app"
    assert "Opening Spotify" in payload["note"]
    assert len(runs) == 1


def test_a_listed_phone_that_isnt_playing_anything_is_woken_with_a_resume(monkeypatch, spawned, car_turn) -> None:
    # 00:18: "nothing playing anywhere" for 30 s while the link opened seven times. Live at
    # 00:10 a resume aimed at the listed iPhone is what made it play from cold.
    phone, runs = car_turn
    stub = _PlayerStub(device_polls=[[PHONE]],
                       playback_states=[{"empty": True}, {"empty": True}, _playing(TRACK)])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK])

    assert _run(runs) == "played"
    assert stub.resume_calls == [{"device_id": "phone-1"}]
    assert stub.play_calls == []


def test_a_woken_phone_on_another_song_is_switched_to_the_asked_one(monkeypatch, spawned, car_turn) -> None:
    phone, runs = car_turn
    stub = _PlayerStub(device_polls=[[PHONE]],
                       playback_states=[{"empty": True}, {"empty": True}, _playing(OTHER_TRACK), _playing(TRACK)])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK])

    assert _run(runs) == "played"
    assert stub.resume_calls == [{"device_id": "phone-1"}]
    assert stub.pause_calls == 1 and len(_opens(phone)) == 2  # the first open, then after the pause
    assert stub.play_calls == []


def test_a_phone_paused_on_another_song_gets_the_link_not_a_resume(monkeypatch, spawned, car_turn) -> None:
    # 00:12: active, paused, holding nothing useful — the link opened then plays.
    phone, runs = car_turn
    stub = _PlayerStub(device_polls=[[PHONE_ACTIVE]],
                       playback_states=[{"empty": True}, _playing(OTHER_TRACK, is_playing=False), _playing(TRACK)])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK])

    assert _run(runs) == "played"
    assert stub.resume_calls == [] and len(_opens(phone)) == 2


GUEST_PHONE = {"id": "guest-1", "name": "Nandhini's Z Flip7", "type": "Smartphone", "is_restricted": False,
               "is_active": False}
SPOTIFY_IPHONE = {"id": "phone-1", "name": "iPhone", "type": "Smartphone", "is_restricted": False, "is_active": False}


def test_a_phone_turn_never_picks_someone_elses_phone():
    # 2026-10-21 00:22: Spotify listed "Nandhini's Z Flip7" (a phone on his Wi-Fi) before his iPhone.
    picked = spotify_tool._pick_device({"devices": [GUEST_PHONE, SPOTIFY_IPHONE]}, phones_only=True)
    assert picked["id"] == "phone-1"
    assert spotify_tool._pick_device({"devices": [GUEST_PHONE]}, phones_only=True) is None


def test_the_phone_player_wake_never_resumes_someone_elses_phone(monkeypatch, spawned, car_turn) -> None:
    _, runs = car_turn
    stub = _PlayerStub(device_polls=[[GUEST_PHONE]], playback_states=[{"empty": True}])
    _use(monkeypatch, stub)

    _car_play(uris=[TRACK])
    _run(runs)

    assert stub.resume_calls == []


def test_no_turn_picks_someone_elses_phone():
    tv = {"id": "tv-1", "name": "Living Room TV", "type": "TV", "is_restricted": False, "is_active": False}
    assert spotify_tool._pick_device({"devices": [GUEST_PHONE, tv]})["id"] == "tv-1"
    assert spotify_tool._pick_device({"devices": [GUEST_PHONE]}) is None
