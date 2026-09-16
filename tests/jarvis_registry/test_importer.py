"""The one-time workspace migration: what moves, what stays, what gets deleted."""
from __future__ import annotations

import json
import tarfile
import time

import pytest

import jarvis_registry.importer as importer
import jarvis_registry.store as store
from jarvis_registry import Registry
from jarvis_registry.importer import Plan, Source

LEDGER = (
    "session_id,date,casino,game,buy_in,cash_out,net_cash\n"
    "a1,2026-01-03,Livermore,BJ,20.00,62.00,42.00\n"
    "a2,2026-01-17,Yaamava,\"BJ, War\",100.00,215.00,115.00\n"
)


@pytest.fixture()
def workspace(tmp_path, monkeypatch):
    reg = Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store, "shared", lambda: reg)

    ws = tmp_path / "workspace"
    (ws / "casino-earnings-tracker").mkdir(parents=True)
    (ws / "casino-earnings-tracker" / "ledger.csv").write_text(LEDGER)
    (ws / "casino-earnings-tracker" / "summary.json").write_text('{"net_cash": 157.0}')
    (ws / "casino-earnings-tracker" / "log_session.py").write_text("# the script the cron runs\n")
    (ws / "email-monitor" / ".backups").mkdir(parents=True)
    (ws / "email-monitor" / "state.json").write_text('{"last_seen_email_id": "99"}')
    (ws / "email-monitor" / ".backups" / "life_log_before_x.json").write_text('{"bills": []}')

    yield {"ws": ws, "reg": reg}
    reg.close()


PLANS = [
    Plan("casino", "Casino Earnings", "Visits and earnings", "chips",
         [Source("casino-earnings-tracker/ledger.csv", collection="sessions",
                 description="one casino visit", ts_field="date"),
          Source("casino-earnings-tracker/summary.json", document="summary")],
         ["casino*"]),
    Plan("email-monitor", "Email Monitor", "Inbox watching", "envelope",
         [Source("email-monitor/state.json", document="inbox_state"),
          Source("email-monitor/.backups/*.json", collection="backups", delete=True)],
         ["email-*"]),
]


@pytest.fixture()
def jobs(monkeypatch):
    store_ = [{"id": "j1", "name": "casino-nightly"},
              {"id": "j2", "name": "email-actionable-monitor"},
              {"id": "j3", "name": "Some Other Thing"}]
    monkeypatch.setattr("cron.jobs.list_jobs", lambda include_disabled=False: store_)

    def update(job_id, updates):
        for job in store_:
            if job["id"] == job_id:
                job.update(updates)
        return None

    monkeypatch.setattr("cron.jobs.update_job", update)
    return store_


def test_a_csv_becomes_records_and_an_object_becomes_a_document(workspace, jobs):
    importer.import_all(workspace["ws"], plans=PLANS)

    casino = workspace["reg"].open("casino")
    rows = casino.records("sessions", limit=10)
    assert [r["casino"] for r in rows] == ["Yaamava", "Livermore"]   # newest first, by date
    assert rows[0]["net_cash"] == 115.0                              # a number, not "115.00"
    assert rows[0]["game"] == "BJ, War"                              # quoted comma survives
    assert rows[1]["ts"] < rows[0]["ts"]                             # the date column is the time
    # A date with no time must land on that date everywhere, not the evening before.
    assert time.strftime("%Y-%m-%d", time.gmtime(rows[1]["ts"])) == "2026-01-03"
    assert casino.get("summary") == {"net_cash": 157.0}
    assert casino.collections()[0]["description"] == "one casino visit"


def test_live_files_stay_and_dead_ones_are_archived_then_deleted(workspace, jobs):
    report = importer.import_all(workspace["ws"], plans=PLANS)
    ws = workspace["ws"]

    # Imported, and still where the running job expects it.
    assert (ws / "email-monitor" / "state.json").exists()
    assert workspace["reg"].open("email-monitor").get("inbox_state") == {"last_seen_email_id": "99"}
    # A rotated backup nothing reads: gone, but inside the tarball first.
    assert not (ws / "email-monitor" / ".backups" / "life_log_before_x.json").exists()
    with tarfile.open(report["archive"]) as tar:
        assert "email-monitor/.backups/life_log_before_x.json" in tar.getnames()
    # The script the schedule runs is never touched.
    assert (ws / "casino-earnings-tracker" / "log_session.py").exists()


def test_running_it_twice_imports_nothing_twice(workspace, jobs):
    importer.import_all(workspace["ws"], plans=PLANS)
    second = importer.import_all(workspace["ws"], plans=PLANS)

    assert second["integrations"][0]["files"] == []
    assert second["integrations"][0]["skipped"] == ["casino-earnings-tracker/ledger.csv",
                                                    "casino-earnings-tracker/summary.json"]
    assert workspace["reg"].open("casino").count("sessions") == 2   # not four


def test_a_corrupt_file_is_reported_and_kept(workspace, jobs):
    broken = workspace["ws"] / "email-monitor" / "state.json"
    broken.write_text('{"last_seen": "99",')          # what reminders.json actually looks like

    report = importer.import_all(workspace["ws"], plans=PLANS)
    email = next(i for i in report["integrations"] if i["id"] == "email-monitor")
    assert email["failed"][0]["file"] == "email-monitor/state.json"
    assert broken.exists()
    assert workspace["reg"].open("email-monitor").get("inbox_state") is None


def test_every_schedule_ends_up_in_an_integration(workspace, jobs):
    plans = PLANS + [Plan("general", "General", "The rest", "dots", [], [])]
    report = importer.import_all(workspace["ws"], plans=plans)

    assert {j["name"]: j["integration"] for j in jobs} == {
        "casino-nightly": "casino",
        "email-actionable-monitor": "email-monitor",
        "Some Other Thing": "general",
    }
    assert report["integrations"][-1]["jobs_tagged"] == ["Some Other Thing"]


def test_same_named_files_in_different_folders_stay_apart(workspace, jobs):
    """Both flight islands keep a state/adaptive_cron_state.json; neither may win."""
    ws = workspace["ws"]
    for trip in ("india", "houston"):
        (ws / f"{trip}-flight-island" / "state").mkdir(parents=True)
        (ws / f"{trip}-flight-island" / "state" / "adaptive_cron_state.json").write_text(
            json.dumps({"trip": trip}))

    plan = Plan("flight", "Flights", "Trips", "airplane",
                [Source("*-flight-island/state/*.json", document=importer.BY_NAME)], [])
    importer.import_all(ws, plans=[plan])

    space = workspace["reg"].open("flight")
    trips = sorted(space.get(d["key"])["trip"] for d in space.documents()
                   if d["key"] != importer.IMPORT_MARKER)
    assert trips == ["houston", "india"]


def test_a_snapshot_file_is_one_record(workspace, jobs):
    ws = workspace["ws"]
    (ws / "snaps").mkdir()
    (ws / "snaps" / "gym_mode_before_1784264441.json").write_text(
        json.dumps([{"track": "a"}, {"track": "b"}, {"track": "c"}]))

    plan = Plan("vibeforge", "VibeForge", "Music", "music",
                [Source("snaps/*.json", collection="playlist_snapshots", whole_file=True)], [])
    importer.import_all(ws, plans=[plan])

    rows = workspace["reg"].open("vibeforge").records("playlist_snapshots", limit=10)
    assert len(rows) == 1                                   # one playlist, not three tracks
    assert [t["track"] for t in rows[0]["value"]] == ["a", "b", "c"]
    assert rows[0]["ts"] == 1784264441.0                    # the epoch in the file name


def test_a_written_up_summary_becomes_a_dated_record(workspace, jobs):
    ws = workspace["ws"]
    (ws / "snaps").mkdir()
    (ws / "snaps" / "weekly_summary_20260913.md").write_text("# Week in music\nTop artist: X\n")

    plan = Plan("vibeforge", "VibeForge", "Music", "music",
                [Source("snaps/*.md", collection="weekly_summaries")], [])
    importer.import_all(ws, plans=[plan])

    rows = workspace["reg"].open("vibeforge").records("weekly_summaries", limit=5)
    assert rows[0]["text"].startswith("# Week in music")
    assert time.strftime("%Y-%m-%d", time.gmtime(rows[0]["ts"])) == "2026-09-13"


def test_the_marker_document_records_what_it_took(workspace, jobs):
    importer.import_all(workspace["ws"], plans=PLANS)
    marker = workspace["reg"].open("casino").get(importer.IMPORT_MARKER)
    assert marker["casino-earnings-tracker/ledger.csv"]["records"] == 2
    assert len(marker["casino-earnings-tracker/ledger.csv"]["sha"]) == 32


def test_two_long_paths_that_share_a_head_stay_two_documents(workspace, jobs):
    """slug() keeps the first 64 characters, so the tail is what tells these apart."""
    ws = workspace["ws"]
    (ws / "flight-tracking-common" / "state").mkdir(parents=True)
    for day in ("2026-09-20", "2026-09-27"):
        (ws / "flight-tracking-common" / "state"
         / f"flight_notification_state_AA100_{day}.json").write_text(json.dumps({"day": day}))

    plan = Plan("flight", "Flights", "Trips", "airplane",
                [Source("flight-tracking-common/state/*.json", document=importer.BY_NAME)], [])
    importer.import_all(ws, plans=[plan])

    space = workspace["reg"].open("flight")
    days = sorted(space.get(d["key"])["day"] for d in space.documents()
                  if d["key"] != importer.IMPORT_MARKER)
    assert days == ["2026-09-20", "2026-09-27"]


def test_a_file_that_fails_halfway_leaves_nothing_behind(workspace, jobs):
    """Otherwise a re-run appends the surviving rows a second time."""
    ws = workspace["ws"]
    oversized = "x" * (store.MAX_RECORD_BYTES + 10)
    (ws / "casino-earnings-tracker" / "ledger.csv").write_text(
        "session_id,date,notes\na,2026-01-03,ok\nb,2026-01-04,ok\nc,2026-01-05," + oversized + "\n")

    for _ in range(2):
        report = importer.import_all(ws, plans=PLANS)
        casino = next(i for i in report["integrations"] if i["id"] == "casino")
        assert casino["failed"][0]["file"] == "casino-earnings-tracker/ledger.csv"
    assert workspace["reg"].open("casino").count("sessions") == 0


def test_a_column_the_store_reserves_is_kept_under_another_name(workspace, jobs):
    ws = workspace["ws"]
    (ws / "casino-earnings-tracker" / "ledger.csv").write_text(
        "session_id,date,ts,net_cash\na,2026-01-03,my-own-stamp,42\n")

    importer.import_all(ws, plans=PLANS)
    row = workspace["reg"].open("casino").records("sessions")[0]
    assert row["source_ts"] == "my-own-stamp"     # kept
    assert isinstance(row["ts"], float)           # and the record's real time survives


def test_bytes_that_are_not_utf8_are_a_failure_not_a_silent_mangling(workspace, jobs):
    ws = workspace["ws"]
    (ws / "email-monitor" / "state.json").write_bytes(b'{"who": "caf\xe9"}')

    report = importer.import_all(ws, plans=PLANS)
    email = next(i for i in report["integrations"] if i["id"] == "email-monitor")
    assert email["failed"][0]["file"] == "email-monitor/state.json"
    assert (ws / "email-monitor" / "state.json").exists()


def test_truncation_is_reported_rather_than_passed_off_as_the_whole_file(workspace, jobs,
                                                                        monkeypatch):
    monkeypatch.setattr(importer, "_MAX_RECORDS_PER_FILE", 2)
    ws = workspace["ws"]
    (ws / "casino-earnings-tracker" / "ledger.csv").write_text(
        "session_id,date\n" + "".join(f"s{i},2026-01-0{i+1}\n" for i in range(5)))

    importer.import_all(ws, plans=PLANS)
    marker = workspace["reg"].open("casino").get(importer.IMPORT_MARKER)
    entry = marker["casino-earnings-tracker/ledger.csv"]
    assert entry["records"] == 2 and entry["truncated"] == 3


def test_the_timestamps_real_files_actually_carry(workspace):
    from jarvis_registry.importer import _row_time

    assert _row_time({"d": "2026-01-03T12:00:00Z"}, "d") == 1767441600.0
    assert _row_time({"d": "2026-01-03T12:00:00+00:00"}, "d") == 1767441600.0
    assert _row_time({"d": "1784264441"}, "d") == 1784264441.0      # epoch as a string
    assert _row_time({"d": 1784264441000}, "d") == 1784264441.0     # milliseconds
    assert _row_time({"d": True}, "d") is None                      # not a time
    assert _row_time({"d": "not a date"}, "d") is None


def test_a_number_that_only_looks_like_one_stays_text():
    from jarvis_registry.importer import _coerce

    assert _coerce("007") == "007"        # an id, not seven
    assert _coerce("1_0") == "1_0"        # int() would read 10
    assert _coerce("nan") == "nan"        # not a value JSON can carry
    assert _coerce("inf") == "inf"
    assert _coerce("-12.5") == -12.5
    assert _coerce("42") == 42
