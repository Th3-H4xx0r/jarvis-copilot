"""The door alarm as a Power integration: protected, off only while disarmed, a real stop."""
from __future__ import annotations

import sys
import threading
import time
from pathlib import Path

import pytest

from jarvis_power import PowerError, discovery, state, switch

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "webui"))


@pytest.fixture()
def door(monkeypatch, tmp_path):
    from plugins.door_alarm import service as svc
    from plugins.door_alarm.store import DoorStore
    s = svc.DoorService(store=DoorStore(tmp_path / "door"), run=lambda fn: None)
    monkeypatch.setattr(svc.DoorService, "_instance", s)
    yield s
    s.stop()


@pytest.mark.parametrize("alarm_state", ["arming", "armed_away", "armed_home", "entry", "triggered"])
@pytest.mark.parametrize("by", ["app", "web", "mac", "jarvis"])
def test_door_off_refused_unless_disarmed(reg, door, alarm_state, by):
    discovery.reset()
    state.ensure_all()
    door.alarm.state = alarm_state
    with pytest.raises(PowerError, match="Disarm the alarm first"):
        switch.request_enabled("door-alarm", False, by=by)
    assert state.is_on("door-alarm") is True


def test_door_off_when_disarmed_needs_face_id(reg, door, monkeypatch):
    from jarvis_power import approvals
    approvals.reset()
    monkeypatch.setattr(approvals, "notifier", lambda item: None)
    discovery.reset()
    state.ensure_all()
    door.alarm.state = "disarmed"
    out = switch.request_enabled("door-alarm", False, by="app")
    assert out["ok"] is False and out["pending"]["command"] == "off:door-alarm"


def _timer_threads():
    return [t for t in threading.enumerate() if t.name == "door-alarm-timer" and t.is_alive()]


def test_door_stop_stops_every_thread_and_handler(door):
    from api import device_bridge
    door.start()
    assert _timer_threads()
    assert "door_report" in device_bridge._EVENT_HANDLERS
    door.stop()
    time.sleep(1.3)
    assert not _timer_threads()
    assert "door_report" not in device_bridge._EVENT_HANDLERS
    assert door._feed is None


def test_door_start_after_stop_works(door):
    door.start()
    door.stop()
    door.start()
    time.sleep(1.3)
    assert len(_timer_threads()) == 1


def test_door_settings_are_app_only():
    discovery.reset()
    p = discovery.get("door-alarm")
    assert p.protected and all(s.jarvis == "never" for s in p.settings)
