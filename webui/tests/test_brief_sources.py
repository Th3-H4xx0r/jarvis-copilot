"""The brief's web-server sources and the phone's context snapshot."""
from __future__ import annotations

import json
import sys
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import api.brief_sources as bs  # noqa: E402
import api.memory_map as mm  # noqa: E402
from plugins.memory.jarvis_memory import brief, tz  # noqa: E402
from plugins.memory.jarvis_memory.brief import BriefCtx  # noqa: E402

CT = ZoneInfo("America/Chicago")
NOW = datetime(2026, 10, 21, 20, 56, tzinfo=CT)


@pytest.fixture(autouse=True)
def _home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from plugins.memory.jarvis_memory import external
    external._handles.clear()
    tz.reset_cache()
    yield tmp_path
    tz.reset_cache()


def _ctx():
    return BriefCtx(now=NOW, zone=CT, store=None, namespace="global")


class _Captured:
    def __init__(self):
        self.calls = []


def _capture(monkeypatch):
    got = _Captured()
    import api.helpers as helpers
    monkeypatch.setattr(helpers, "j", lambda h, payload, status=200, **k: got.calls.append((status, payload)))
    return got


def test_snapshot_post_writes_file_and_marks_dirty(monkeypatch, _home):
    import api.auth, api.pairing
    monkeypatch.setattr(api.auth, "parse_cookie", lambda h: "cookie")
    monkeypatch.setattr(api.pairing, "find_device_by_session", lambda c: {"id": "phone1"})
    got = _capture(monkeypatch)
    state = brief._state_for("global")
    state["dirty"].clear()
    mm.handle_context_post(object(), {
        "tz": "America/New_York",
        "calendar": [{"title": "Mom's Bday", "start_iso": "2026-10-23T00:00:00-05:00", "all_day": True},
                     {"title": ""}],
        "reminders": [{"title": "Buy parking pass", "due_iso": None, "list": "Errands"}],
        "sent_at": "2026-10-21T20:50:00-05:00"})
    status, payload = got.calls[-1]
    assert status == 200 and payload["calendar"] == 1 and payload["reminders"] == 1
    snap = json.loads((_home / "memory" / "context_snapshot.json").read_text())
    assert snap["tz"] == "America/New_York" and snap["calendar"][0]["title"] == "Mom's Bday"
    assert tz.user_zone().key == "America/New_York"
    assert state["dirty"].is_set()


def test_snapshot_rejects_unpaired(monkeypatch, _home):
    import api.auth, api.pairing
    monkeypatch.setattr(api.auth, "parse_cookie", lambda h: "")
    monkeypatch.setattr(api.pairing, "find_device_by_session", lambda c: None)
    got = _capture(monkeypatch)
    mm.handle_context_post(object(), {"tz": "UTC"})
    assert got.calls[-1][0] == 401
    assert not (_home / "memory" / "context_snapshot.json").exists()


def test_bad_time_zone_is_dropped(_home):
    assert bs.save_snapshot({"tz": "Mars/Base"})["tz"] == ""


def test_calendar_source_window_14_days(_home):
    bs.save_snapshot({"tz": "America/Chicago", "calendar": [
        {"title": "Race", "start_iso": "2026-10-24T09:00:00-05:00"},
        {"title": "Too far", "start_iso": "2026-11-20T09:00:00-06:00"},
        {"title": "Long gone", "start_iso": "2026-09-01T09:00:00-05:00"},
        {"title": "Floating", "start_iso": "2026-10-22T10:00:00"}]})
    titles = [i["title"] for i in bs.calendar_items(_ctx())]
    assert titles == ["Race", "Floating"]


def test_tasks_source_lists_one_shot_cron_as_reminder(monkeypatch, _home):
    import cron.jobs
    monkeypatch.setattr(cron.jobs, "list_jobs", lambda include_disabled=False: [
        {"name": "Call the dentist", "repeat": {"times": 1}, "next_run_at": "2026-10-22T09:00:00-05:00"},
        {"name": "Email digest", "repeat": {"times": None}, "next_run_at": "2026-10-22T09:00:00-05:00"}])
    bs.save_snapshot({"reminders": [{"title": "Buy parking pass", "due_iso": "2026-10-23T12:00:00-05:00"}]})
    text = bs.tasks_source(_ctx())
    assert "reminder Thu 22 Oct 9:00 AM: Call the dentist" in text
    assert "Email digest" not in text
    assert "Buy parking pass (due Fri 23 Oct)" in text


def test_inbox_source_skips_without_creds(monkeypatch, _home):
    for key in ("EMAIL_ADDRESS", "EMAIL_PASSWORD", "EMAIL_IMAP_HOST"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(bs, "_email_jobs", lambda: [])
    assert bs.check_inbox_once() is None
    assert bs.inbox_source(_ctx()) is None


def test_inbox_source_reads_monitor_output(monkeypatch, _home):
    monkeypatch.setattr(bs, "_email_jobs", lambda: [{"id": "job1", "name": "Email monitor"}])
    folder = _home / "cron" / "output" / "job1"
    folder.mkdir(parents=True)
    (folder / "2026-10-21_20-00-00.md").write_text("# Run\nAmEx statement due Oct 28.\nUPS delivery today.")
    import os
    os.utime(folder / "2026-10-21_20-00-00.md", (NOW.timestamp(), NOW.timestamp()))
    text = bs.inbox_source(_ctx())
    assert "AmEx statement due Oct 28." in text


def test_car_timeout_omits_section(monkeypatch, _home):
    def slow():
        time.sleep(5)
    monkeypatch.setattr(bs, "_car_snapshot", slow)
    brief.reset()
    brief.register_source("home", bs.home_source, order=60, timeout_s=0.3)
    brief.register_source("probe", lambda ctx: "Probe line", order=61)
    from plugins.memory.jarvis_memory.store import MemoryStore
    store = MemoryStore(_home / "m.db", _home / "v")
    t0 = time.perf_counter()
    text = brief.build(store, "global", now=NOW)
    assert time.perf_counter() - t0 < 2
    assert "Probe line" in text and "car:" not in text
    brief.reset()


def test_messages_source(monkeypatch, _home):
    import api.imessage_memory as im

    class Fake:
        def waiting_threads(self, since):
            return [{"guid": "g", "name": "Sid", "last_sender": "Sid", "last_at": NOW.timestamp() - 7200}]
    monkeypatch.setattr(im, "store", lambda: Fake())
    assert bs.messages_source(_ctx()) == "Messages waiting on you: Sid (2 h ago)"


def test_inbox_reads_the_response_of_a_real_cron_output(monkeypatch, _home):
    import os
    monkeypatch.setattr(bs, "_email_jobs", lambda: [{"id": "job1", "name": "Email monitor"}])
    folder = _home / "cron" / "output" / "job1"
    folder.mkdir(parents=True)
    f = folder / "2026-10-21_20-00-00.md"
    f.write_text("# Cron Job: Email monitor\n\n**Job ID:** job1\n**Run Time:** 2026-10-21 20:00:00\n"
                 "**Schedule:** every 15m\n**Runs on:** x\n\n## Prompt\n\nCheck my inbox.\n\n"
                 "## Response\n\nAmEx statement due Oct 28.\nUPS delivery today.\n")
    os.utime(f, (NOW.timestamp(), NOW.timestamp()))
    text = bs.inbox_source(_ctx())
    assert "AmEx statement due Oct 28." in text and "Job ID" not in text and "Check my inbox" not in text


def test_car_line_uses_the_snapshot_fields(monkeypatch, _home):
    monkeypatch.setattr(bs, "_car_snapshot", lambda: {"car": {
        "range_mi": 240, "fuel_pct": 62, "odometer_mi": 18000, "doors": {"open": [], "locked": True},
        "location": {"lat": 30.2, "lon": -97.7, "at": "x", "source": "gps"}}})
    import plugins.door_alarm.service as door
    monkeypatch.setattr(door.DoorService, "instance", classmethod(lambda cls: (_ for _ in ()).throw(RuntimeError())))
    text = bs.home_source(_ctx())
    assert "fuel 62%" in text and "range 240 mi" in text and "locked" in text
    assert "'lat'" not in text


def test_habit_streak_counts_from_quit_date_or_last_relapse(monkeypatch, _home):
    import jarvis_health.store as hs
    import jarvis_health.window as win

    class Store:
        def habits(self):
            return [{"id": "h1", "name": "Vaping", "started_at": "2026-10-01T05:00:00Z"},
                    {"id": "h2", "name": "Soda", "started_at": "2026-09-01T05:00:00Z"}]

        def latest_relapse(self, hid):
            return {"at": "2026-10-18T05:00:00Z"} if hid == "h2" else None

        def workouts(self, *a):
            return []
    monkeypatch.setattr(hs, "HealthStore", Store)
    monkeypatch.setattr(win, "today", lambda store, now: {"start": "x", "stats": {}, "battery": {}})
    text = bs.health_source(_ctx())
    assert "Vaping 20 d" in text and "Soda 3 d" in text


def test_calendar_leaves_out_what_already_ended(_home):
    bs.save_snapshot({"calendar": [
        {"title": "This morning standup", "start_iso": "2026-10-21T14:00:00Z", "end_iso": "2026-10-21T14:30:00Z"},
        {"title": "Going on now", "start_iso": "2026-10-22T01:00:00Z", "end_iso": "2026-10-22T03:00:00Z"},
        {"title": "Tomorrow", "start_iso": "2026-10-22T15:00:00Z"}]})
    assert [i["title"] for i in bs.calendar_items(_ctx())] == ["Going on now", "Tomorrow"]


def test_quiet_inbox_runs_and_jarvis_threads_are_left_out(monkeypatch, _home):
    import os
    monkeypatch.setattr(bs, "_email_jobs", lambda: [{"id": "job1", "name": "email monitor"}])
    folder = _home / "cron" / "output" / "job1"
    folder.mkdir(parents=True)
    f = folder / "run.md"
    f.write_text("# Cron Job: x\n\n## Response\n\nNo new email activity.\n")
    os.utime(f, (NOW.timestamp(), NOW.timestamp()))
    assert bs.inbox_source(_ctx()) is None
    import api.imessage_memory as im

    class Fake:
        def waiting_threads(self, since):
            return [{"guid": "j", "name": "Jarvis", "last_sender": "Jarvis", "last_at": NOW.timestamp()},
                    {"guid": "s", "name": "Sid", "last_sender": "Sid", "last_at": NOW.timestamp() - 60}]
    monkeypatch.setattr(im, "store", lambda: Fake())
    assert bs.messages_source(_ctx()) == "Messages waiting on you: Sid (1 min ago)"
