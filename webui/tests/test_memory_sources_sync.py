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
    for name in ("_email_jobs", "_other_jobs", "_health_line", "_places", "_drives"):
        monkeypatch.setattr(sync, name, lambda *a, **k: [] if name != "_health_line" else None)
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


def test_health_places_and_drives(home, monkeypatch):
    monkeypatch.setattr(sync, "_health_line", lambda ctx: "woke 5:25 AM; Body Battery 27 (Low)")
    monkeypatch.setattr(sync, "_places", lambda day, zone: ["Pease Street, Downtown", "Minute Maid Park"]
                        if day.date() == NOW.date() else [])
    monkeypatch.setattr(sync, "_drives", lambda since: [
        {"id": "d1", "start": NOW.timestamp() - 3600, "end": NOW.timestamp() - 1800, "distance_m": 16093.4}])
    sync.sync_once(now=NOW)
    assert [m["body"] for m in _memories("health:")] == ["Health on Wed 21 Oct: woke 5:25 AM; Body Battery 27 (Low)"]
    assert [m["body"] for m in _memories("location:")] == ["Places on Wed 21 Oct: Pease Street, Downtown; Minute Maid Park"]
    assert [m["body"] for m in _memories("dashcam:")] == ["Drove 10 mi on Wed 21 Oct, 7:56–8:26 PM"]
    monkeypatch.setattr(sync, "_health_line", lambda ctx: "woke 5:25 AM; Body Battery 31 (Low)")
    sync.sync_once(now=NOW)
    assert [m["body"] for m in _memories("health:")] == ["Health on Wed 21 Oct: woke 5:25 AM; Body Battery 31 (Low)"]
