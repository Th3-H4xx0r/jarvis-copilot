"""Every source into the map: calendar, reminders, email, integrations, health, places, drives."""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import api.brief_sources as bs  # noqa: E402
import api.memory_sources_sync as sync  # noqa: E402

CT = ZoneInfo("America/Chicago")
NOW = datetime(2026, 10, 21, 20, 56, tzinfo=CT)


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from plugins.memory.jarvis_memory import external, tz
    external._handles.clear()
    monkeypatch.setattr(external, "load_config", lambda _h: {
        "embedder": "fake", "embed_dim": 64, "namespace": "global", "dedup_threshold": 0.92,
        "db_path": str(tmp_path / "memory" / "memory.db"), "vault_dir": str(tmp_path / "memory" / "vault")})
    monkeypatch.setattr(tz, "user_zone", lambda: CT)
    for name in ("_email_jobs", "_other_jobs", "_health_line_for", "_places", "_drives"):
        monkeypatch.setattr(sync, name, lambda *a, **k: [] if name != "_health_line_for" else None)
    monkeypatch.setattr(external, "is_active", lambda: True)
    return tmp_path


def _memories(prefix):
    from plugins.memory.jarvis_memory import external
    return external.memories(prefix, limit=100)


def test_calendar_and_reminders_follow_the_snapshot(home):
    bs.save_snapshot({"tz": "America/Chicago", "calendar": [
        {"title": "Dentist", "start_iso": "2026-10-22T14:00:00Z", "end_iso": "2026-10-22T15:00:00Z",
         "location": "Main St Dental"},
        {"title": "F1 weekend", "start_iso": "2026-10-23T05:00:00Z", "end_iso": "2026-10-26T05:00:00Z",
         "all_day": True}],
        "reminders": [{"title": "Buy parking pass", "due_iso": None, "list": "Errands"}]})
    counts = sync.sync_once(now=NOW)
    cal = _memories("calendar:")
    assert counts["calendar"] == 2 and len(cal) == 2
    dentist = next(m for m in cal if "Dentist" in m["body"])
    assert dentist["body"] == "Calendar: Dentist, Thu 22 Oct 9:00 AM @ Main St Dental"
    assert [m["body"] for m in _memories("reminder:")] == ["Reminder: Buy parking pass (Errands)"]
    assert sync.sync_once(now=NOW)["calendar"] == 0  # nothing new
    bs.save_snapshot({"tz": "America/Chicago", "calendar": [
        {"title": "F1 weekend", "start_iso": "2026-10-23T05:00:00Z", "end_iso": "2026-10-26T05:00:00Z",
         "all_day": True}], "reminders": []})
    sync.sync_once(now=NOW)
    assert [m["body"] for m in _memories("calendar:")] == ["Calendar: F1 weekend, Fri 23 Oct – Sun 25 Oct"]
    assert _memories("reminder:") == []


def test_email_and_integration_runs_become_memories(home, monkeypatch):
    folder = home / "cron" / "output" / "job1"
    folder.mkdir(parents=True)
    run = folder / "2026-10-21_20-00-00.md"
    run.write_text("# Cron Job: x\n\n## Response\n\nAmEx statement due Oct 28.\n")
    os.utime(run, (NOW.timestamp(), NOW.timestamp()))
    quiet = folder / "2026-10-21_20-15-00.md"
    quiet.write_text("# Cron Job: x\n\n## Response\n\nNo new email activity.\n")
    os.utime(quiet, (NOW.timestamp(), NOW.timestamp()))
    monkeypatch.setattr(sync, "_email_jobs", lambda: [{"id": "job1", "name": "Email monitor"}])
    other = home / "cron" / "output" / "job2"
    other.mkdir(parents=True)
    f = other / "2026-10-21_19-00-00.md"
    f.write_text("# Cron Job: y\n\n## Response\n\nFlight AA100 is on time, gate B12.\n")
    os.utime(f, (NOW.timestamp(), NOW.timestamp()))
    monkeypatch.setattr(sync, "_other_jobs", lambda: [{"id": "job2", "name": "Flight tracking"}])
    sync.sync_once(now=NOW)
    assert [m["body"] for m in _memories("email:")] == ["Email monitor, Wed 21 Oct: AmEx statement due Oct 28."]
    assert [m["body"] for m in _memories("cron:")] == ["Flight tracking, Wed 21 Oct: Flight AA100 is on time, gate B12."]


def _cal(title, start_iso, end_iso=None):
    return {"title": title, "start_iso": start_iso, "end_iso": end_iso}


def test_a_snapshot_without_calendar_or_reminders_forgets_nothing(home):
    bs.save_snapshot({"tz": "America/Chicago", "calendar": [_cal("Dentist", "2026-10-22T14:00:00Z")],
                      "reminders": [{"title": "Buy parking pass"}]})
    sync.sync_once(now=NOW)
    bs.save_snapshot({"tz": "America/Chicago"})  # no access / keys left out
    sync.sync_once(now=NOW)
    assert len(_memories("calendar:")) == 1 and len(_memories("reminder:")) == 1


def test_only_events_inside_the_phones_window_can_be_forgotten(home):
    bs.save_snapshot({"calendar": [_cal("Dentist", "2026-10-22T14:00:00Z"),
                                   _cal("Ski trip", "2026-12-20T14:00:00Z")]})
    sync.sync_once(now=NOW)
    bs.save_snapshot({"calendar": [_cal("Dentist", "2026-10-22T14:00:00Z")]})
    sync.sync_once(now=NOW)
    assert len(_memories("calendar:")) == 2  # Dec 20 is past the 14-day window, not cancelled


def test_calendar_key_survives_a_different_time_format(home):
    bs.save_snapshot({"calendar": [_cal("Dentist", "2026-10-22T14:00:00Z")]})
    sync.sync_once(now=NOW)
    bs.save_snapshot({"calendar": [_cal("Dentist", "2026-10-22T09:00:00-05:00")]})
    assert sync.sync_once(now=NOW)["calendar"] == 0
    assert len(_memories("calendar:")) == 1


def test_health_and_places_are_written_for_the_day_just_finished(home, monkeypatch):
    monkeypatch.setattr(sync, "_health_line_for", lambda day, zone: "slept 7 h; Body Battery 80")
    monkeypatch.setattr(sync, "_places", lambda day, zone: ["Pease Street"] if day.day == 20 else ["Elsewhere"])
    sync.sync_once(now=NOW)
    assert [m["body"] for m in _memories("health:")] == ["Health on Tue 20 Oct: slept 7 h; Body Battery 80"]
    assert [m["body"] for m in _memories("location:")] == ["Places on Tue 20 Oct: Pease Street"]


def test_a_drive_keeps_one_memory_while_its_clips_arrive(home, monkeypatch):
    end = NOW.timestamp() - 7200
    monkeypatch.setattr(sync, "_drives", lambda since: [
        {"id": "dr_1_a", "camera_id": "cam", "start": end - 600, "end": end, "distance_m": 8000}])
    sync.sync_once(now=NOW)
    monkeypatch.setattr(sync, "_drives", lambda since: [
        {"id": "dr_0_b", "camera_id": "cam", "start": end - 1800, "end": end, "distance_m": 16093.4}])
    sync.sync_once(now=NOW)
    assert [m["body"] for m in _memories("dashcam:")] == ["Drove 10 mi on Wed 21 Oct, 6:26–6:56 PM"]


def test_a_drive_still_going_is_not_written_yet(home, monkeypatch):
    monkeypatch.setattr(sync, "_drives", lambda since: [
        {"id": "d", "camera_id": "cam", "start": NOW.timestamp() - 900, "end": NOW.timestamp() - 60,
         "distance_m": 5000}])
    sync.sync_once(now=NOW)
    assert _memories("dashcam:") == []


def test_a_hidden_synced_item_is_not_written_again(home):
    from plugins.memory.jarvis_memory import external
    bs.save_snapshot({"calendar": [_cal("Standup", "2026-10-22T14:00:00Z")]})
    sync.sync_once(now=NOW)
    store = external._open()[0]
    [cid] = store.active_ids(source_prefix="calendar:")
    store.set_status([cid], "hidden")
    assert sync.sync_once(now=NOW)["calendar"] == 0
    assert store.active_ids(source_prefix="calendar:") == []


def test_sync_does_nothing_when_another_memory_is_active(home, monkeypatch):
    from plugins.memory.jarvis_memory import external
    monkeypatch.setattr(external, "is_active", lambda: False)
    bs.save_snapshot({"calendar": [_cal("Dentist", "2026-10-22T14:00:00Z")]})
    assert sync.sync_once(now=NOW) == {}


def _run_file(home, job, name, text):
    folder = home / "cron" / "output" / job
    folder.mkdir(parents=True, exist_ok=True)
    f = folder / f"{name}.md"
    f.write_text("# Cron Job: x\n\n## Response\n\n" + text + "\n")
    os.utime(f, (NOW.timestamp(), NOW.timestamp()))


def test_status_only_and_failed_runs_are_not_memories(home, monkeypatch):
    monkeypatch.setattr(sync, "_email_jobs", lambda: [{"id": "job1", "name": "email monitor"}])
    _run_file(home, "job1", "a", "Email intelligence run complete.")
    _run_file(home, "job1", "b", "Email intelligence run failed: I could not start it. The tools are missing.")
    _run_file(home, "job1", "c", "Run complete. AmEx statement of $412 is due Oct 28; UPS delivers the monitor today.")
    sync.sync_once(now=NOW)
    assert [m["body"] for m in _memories("email:")] == [
        "email monitor, Wed 21 Oct: Run complete. AmEx statement of $412 is due Oct 28; UPS delivers the monitor today."]


def test_the_same_report_twice_is_one_memory(home, monkeypatch):
    monkeypatch.setattr(sync, "_email_jobs", lambda: [{"id": "job1", "name": "email monitor"}])
    _run_file(home, "job1", "a", "AmEx statement of $412 is due Oct 28.")
    _run_file(home, "job1", "b", "AmEx statement of $412 is due Oct 28.")
    sync.sync_once(now=NOW)
    from plugins.memory.jarvis_memory import external
    store = external._open()[0]
    assert len(store.active_ids(source_prefix="email:")) == 1


def test_noise_written_before_is_cleared(home, monkeypatch):
    from plugins.memory.jarvis_memory import external
    external.upsert("email monitor, Wed 21 Oct: Email intelligence run complete.", source="email:job1:old")
    monkeypatch.setattr(sync, "_email_jobs", lambda: [])
    sync.sync_once(now=NOW)
    assert _memories("email:") == []


def test_machine_output_and_dividers(home, monkeypatch):
    monkeypatch.setattr(sync, "_email_jobs", lambda: [])
    monkeypatch.setattr(sync, "_other_jobs", lambda: [{"id": "h", "name": "Jarvis Health"},
                                                      {"id": "f", "name": "Flight tracking"}])
    _run_file(home, "h", "a", '--- {"space": "jarvis-health", "scores": {"sleep": {"value": 81}}}')
    _run_file(home, "f", "a", "---\nFlight AA100 to Austin leaves Fri 7:05 AM from gate B12.")
    sync.sync_once(now=NOW)
    assert [m["body"] for m in _memories("cron:")] == [
        "Flight tracking, Wed 21 Oct: Flight AA100 to Austin leaves Fri 7:05 AM from gate B12."]
