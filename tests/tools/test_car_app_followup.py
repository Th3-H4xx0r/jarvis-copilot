"""tools/car_app_followup: open an app on the turn's device, then run the command
once the app is up — the template for CarPlay commands that need an app open.

Synchronous: the background runner is captured through ``spawn`` and driven with
a fake clock, so no thread is left behind.
"""

from __future__ import annotations

import logging
import sys
import threading
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))

from tools import car_app_followup as followup  # noqa: E402

CAR_NOTE = "It opens on the car's screen when you finish speaking."


class _FakeClock:
    def __init__(self):
        self.now = 0.0
        self.sleeps = 0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps += 1
        self.now += seconds


class _Phone:
    """Records open requests; answers like the phone's open_app on CarPlay."""

    def __init__(self, reply=None):
        self.calls: list = []
        self.reply = reply if reply is not None else {"ok": True, "result": {"launched": True, "note": CAR_NOTE}}

    def __call__(self, device_id, skill, args):
        self.calls.append((device_id, skill, dict(args)))
        return self.reply


def _ready_after(polls: int, value="device"):
    state = {"n": 0}

    def ready():
        state["n"] += 1
        return value if state["n"] > polls else None

    return ready


def _open_then(phone, runs, **kw):
    return followup.open_then(
        kw.pop("app", "spotify"), kw.pop("device_id", "iphone-1"),
        kw.pop("ready", _ready_after(0)), kw.pop("action", lambda value: None),
        invoke=phone, spawn=lambda run, name: runs.append(run), **kw,
    )


# ── open_then: open now, follow up in the background ───────────────────────


def test_open_then_asks_the_device_to_open_the_app_and_returns_at_once():
    phone, runs, acted = _Phone(), [], []

    out = _open_then(phone, runs, action=acted.append)

    assert phone.calls == [("iphone-1", "open_app", {"app": "spotify"})]
    assert out["pending"] is True
    assert out["opened"] is True
    assert out["app"] == "spotify"
    assert out["device_id"] == "iphone-1"
    assert out["device_note"] == CAR_NOTE
    assert out["note"]
    assert len(runs) == 1
    assert acted == []  # nothing runs until the follow-up does


def test_the_follow_up_waits_for_the_app_then_runs_the_action_once():
    phone, runs, acted = _Phone(), [], []
    _open_then(phone, runs, ready=_ready_after(2, value={"id": "spotify-phone"}), action=acted.append)

    clock = _FakeClock()
    outcome = runs[0](sleep=clock.sleep, clock=clock)

    assert outcome == "done"
    assert acted == [{"id": "spotify-phone"}]  # the action gets what ready() found
    assert clock.sleeps == 3


def test_an_action_that_fails_is_retried_on_the_next_tick():
    phone, runs, attempts = _Phone(), [], []

    def action(value):
        attempts.append(value)
        if len(attempts) == 1:
            raise RuntimeError("app is up but not ready for the command")

    _open_then(phone, runs, action=action)
    clock = _FakeClock()

    assert runs[0](sleep=clock.sleep, clock=clock) == "done"
    assert len(attempts) == 2


def test_a_ready_check_that_raises_counts_as_not_yet():
    phone, runs, acted = _Phone(), [], []
    state = {"n": 0}

    def ready():
        state["n"] += 1
        if state["n"] == 1:
            raise ConnectionError("api hiccup")
        return "device"

    _open_then(phone, runs, ready=ready, action=acted.append)
    clock = _FakeClock()

    assert runs[0](sleep=clock.sleep, clock=clock) == "done"
    assert acted == ["device"]


def test_the_follow_up_gives_up_after_the_timeout(caplog):
    phone, runs, acted, timed_out = _Phone(), [], [], []
    _open_then(phone, runs, ready=lambda: None, action=acted.append,
               timeout_s=30.0, poll_s=1.5, on_timeout=lambda: timed_out.append(True),
               label="Podcasts play")
    clock = _FakeClock()

    with caplog.at_level(logging.INFO):
        outcome = runs[0](sleep=clock.sleep, clock=clock)

    assert outcome == "timeout"
    assert acted == []
    assert timed_out == [True]
    assert 30.0 <= clock.now < 30.0 + 2 * 1.5
    assert any("Podcasts play" in r.getMessage() and "gave up" in r.getMessage() for r in caplog.records)


def test_setting_cancelled_stops_the_follow_up_before_the_action():
    phone, runs, acted = _Phone(), [], []
    cancelled = threading.Event()
    _open_then(phone, runs, ready=_ready_after(5), action=acted.append, cancelled=cancelled)
    clock = _FakeClock()

    def sleep_then_cancel(seconds):
        clock.sleep(seconds)
        if clock.sleeps == 2:
            cancelled.set()  # e.g. a newer request, or "pause"

    assert runs[0](sleep=sleep_then_cancel, clock=clock) == "cancelled"
    assert acted == []


def test_an_action_can_cancel_at_the_last_moment():
    phone, runs = _Phone(), []

    def action(value):
        raise followup.Cancelled("superseded")

    _open_then(phone, runs, action=action)
    clock = _FakeClock()

    assert runs[0](sleep=clock.sleep, clock=clock) == "cancelled"
    assert clock.sleeps == 1  # not retried


def test_without_a_device_nothing_is_opened_but_the_follow_up_still_waits():
    phone, runs = _Phone(), []

    out = _open_then(phone, runs, device_id=None)

    assert phone.calls == []
    assert out["opened"] is False
    assert out["pending"] is True
    assert "device_open_app" in out["note"]  # the model has to open it
    assert len(runs) == 1


@pytest.mark.parametrize("reply", [
    {"ok": False, "error": "device offline"},
    {"ok": True, "result": {"launched": False, "error": "not an app this skill may open"}},
    {"ok": True, "result": {"ok": False, "error": "skill failed"}},
])
def test_a_device_that_does_not_open_it_is_reported(reply):
    phone, runs = _Phone(reply=reply), []

    out = _open_then(phone, runs)

    assert out["opened"] is False
    assert out["error"]
    assert "device_open_app" in out["note"]
    assert len(runs) == 1  # still waits: the model may open it


def test_a_deferred_tap_to_run_open_counts_as_opening():
    reply = {"ok": True, "result": {"queued": True, "note": "Sent to your phone — tap the notification to run it."}}
    phone, runs = _Phone(reply=reply), []

    out = _open_then(phone, runs)

    assert out["opened"] is True
    assert "tap the notification" in out["device_note"]


# ── the real background thread ─────────────────────────────────────────────


def test_the_background_thread_runs_the_follow_up_and_exits():
    phone, threads, acted = _Phone(), [], []

    def spawn(run, name):
        thread = followup.start_background(run, name)
        threads.append(thread)
        return thread

    followup.open_then("spotify", "iphone-1", _ready_after(2), acted.append,
                       poll_s=0.01, timeout_s=5.0, invoke=phone, spawn=spawn)
    assert len(threads) == 1
    threads[0].join(timeout=5)

    assert not threads[0].is_alive()
    assert threads[0].daemon
    assert acted == ["device"]


def test_a_crashing_follow_up_is_logged_not_raised(caplog):
    def run():
        raise RuntimeError("boom")

    with caplog.at_level(logging.ERROR):
        thread = followup.start_background(run, "crashy")
        thread.join(timeout=5)

    assert not thread.is_alive()
    assert any("crashy" in r.getMessage() for r in caplog.records)


# ── the default open path and the turn's device ─────────────────────────────


def test_the_default_open_skips_a_device_that_cannot_open_apps(monkeypatch):
    from api import device_bridge

    invoked = []
    monkeypatch.setattr(device_bridge, "in_process_available", lambda: True)
    monkeypatch.setattr(device_bridge, "skills_for_device", lambda device_id: [{"name": "pod_show"}])
    monkeypatch.setattr(device_bridge, "invoke_skill", lambda *a, **k: invoked.append(a) or {"ok": True})

    out = followup.request_open("spotify", "pod-1")

    assert out["opened"] is False
    assert invoked == []


def test_the_default_open_goes_through_the_device_bridge(monkeypatch):
    from api import device_bridge

    invoked = []
    monkeypatch.setattr(device_bridge, "in_process_available", lambda: True)
    monkeypatch.setattr(device_bridge, "skills_for_device", lambda device_id: [{"name": "open_app"}])

    def invoke_skill(device_id, skill, args, timeout=30.0):
        invoked.append((device_id, skill, args, timeout))
        return {"ok": True, "result": {"launched": True, "note": CAR_NOTE}}

    monkeypatch.setattr(device_bridge, "invoke_skill", invoke_skill)

    out = followup.request_open("spotify", "iphone-1")

    assert out == {"opened": True, "device_note": CAR_NOTE, "error": ""}
    assert invoked[0][:3] == ("iphone-1", "open_app", {"app": "spotify"})
    assert invoked[0][3] <= followup.OPEN_TIMEOUT_S


def test_the_default_open_names_the_app_the_way_the_device_asks(monkeypatch):
    # 2026-10-20 23:17: the Mac's open_app takes `name`, not the phone's `app` — "bad args:
    # skill 'open_app' got unexpected args: ['app']", and Spotify never opened on his Mac.
    from api import device_bridge

    invoked = []
    mac_open_app = {"name": "open_app", "input_schema": {
        "type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}}
    monkeypatch.setattr(device_bridge, "in_process_available", lambda: True)
    monkeypatch.setattr(device_bridge, "skills_for_device", lambda device_id: [mac_open_app])
    monkeypatch.setattr(device_bridge, "invoke_skill",
                        lambda device_id, skill, args, timeout=30.0: invoked.append((skill, args)) or {"ok": True})

    out = followup.request_open("spotify", "mac-1")

    assert out["opened"] is True
    assert invoked == [("open_app", {"name": "Spotify"})]


def test_turn_device_is_the_device_the_turn_came_from():
    from api import turn_origin

    turn_origin.note_turn("sess-car", {"device_id": "iphone-1", "name": "iPhone", "kind": "mobile-ios"})
    try:
        assert followup.turn_device("sess-car") == "iphone-1"
        assert followup.turn_device("another-session") is None
        assert followup.turn_device(None) is None
    finally:
        turn_origin.note_turn("sess-car", None)


# ── open a link (open_url) instead of the bare app ──────────────────────────


def test_request_open_with_a_url_asks_the_device_to_open_it_now():
    phone = _Phone()

    out = followup.request_open("spotify", "iphone-1", url="spotify:track:abc", now=True, invoke=phone)

    assert phone.calls == [("iphone-1", "open_url", {"url": "spotify:track:abc", "now": True})]
    assert out["opened"] is True


def test_follow_up_starts_the_runner_in_the_background():
    runs, acted = [], []

    followup.follow_up(_ready_after(1), acted.append, spawn=lambda run, name: runs.append((run, name)),
                       name="spotify-open-play")

    assert len(runs) == 1 and runs[0][1] == "spotify-open-play"
    clock = _FakeClock()
    assert runs[0][0](sleep=clock.sleep, clock=clock) == "done"
    assert acted == ["device"]


# ── who the turn came from ──────────────────────────────────────────────────


def test_turn_origin_and_turn_phone():
    from api import turn_origin

    turn_origin.note_turn("sess-car", {"device_id": "iphone-1", "name": "iPhone", "kind": "mobile-ios"},
                          carplay=True)
    turn_origin.note_turn("sess-web", {"device_id": "web-1", "name": "Brave", "kind": "browser"})
    try:
        car = followup.turn_origin("sess-car")
        assert car["device_id"] == "iphone-1" and car["carplay"] is True
        assert followup.turn_phone("sess-car") == car
        assert followup.turn_origin("sess-web")["carplay"] is False
        assert followup.turn_phone("sess-web") is None
        assert followup.turn_origin(None) is None and followup.turn_phone("nope") is None
    finally:
        turn_origin.note_turn("sess-car", None)
        turn_origin.note_turn("sess-web", None)
