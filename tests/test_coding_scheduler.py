"""Tests for the Coding Sessions message scheduler (agent.coding_scheduler).

Strict-TDD spec for ``CodingScheduler``: a stdlib-only, sqlite-backed
scheduler owning its own ``coding_schedules`` table. All time-dependent
logic takes an explicit ``now`` so the tests are deterministic.
"""
from __future__ import annotations

import sys
from pathlib import Path

# Ensure project root is importable (conftest also does this, but be explicit).
_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from agent.coding_scheduler import CodingScheduler  # noqa: E402


def _db(tmp_path) -> str:
    return str(tmp_path / "coding_sessions.db")


def test_schedule_once_due_and_run(tmp_path):
    sched = CodingScheduler(db_path=_db(tmp_path))
    sid = sched.schedule_once("sess-1", "hello world", run_at=100.0)

    # Not due before its run_at.
    assert sched.due(now=50.0) == []

    # Due at/after run_at.
    due = sched.due(now=150.0)
    assert len(due) == 1
    assert due[0]["id"] == sid
    assert due[0]["session_id"] == "sess-1"
    assert due[0]["message"] == "hello world"
    assert due[0]["kind"] == "once"

    # run_due fires the injected callback then disables the one-off.
    calls: list[tuple[str, str]] = []
    fired = sched.run_due(now=150.0, send=lambda s, m: calls.append((s, m)))
    assert fired == 1
    assert calls == [("sess-1", "hello world")]

    # Now disabled: no longer due, and not enabled in listing.
    assert sched.due(now=150.0) == []
    rows = sched.list_schedules()
    assert len(rows) == 1
    assert rows[0]["enabled"] == 0


def test_schedule_recurring_advances_and_catches_up(tmp_path):
    sched = CodingScheduler(db_path=_db(tmp_path))
    sid = sched.schedule_recurring(
        "sess-2", "tick", interval_seconds=60.0, first_run_at=100.0
    )

    # Due at the first run time.
    due = sched.due(now=100.0)
    assert len(due) == 1
    assert due[0]["id"] == sid
    assert due[0]["kind"] == "recurring"

    # After firing at t=100, next_run advances by one interval to 160.
    sched.mark_fired(sid, now=100.0)
    rows = sched.list_schedules("sess-2")
    assert len(rows) == 1
    assert rows[0]["next_run_at"] == 160.0
    assert rows[0]["enabled"] == 1

    # A long gap (now=400) must catch up past now, not fire repeatedly.
    sched.mark_fired(sid, now=400.0)
    rows = sched.list_schedules("sess-2")
    assert rows[0]["next_run_at"] > 400.0
    # 160 -> 220 -> 280 -> 340 -> 400 -> 460 (first strictly > 400).
    assert rows[0]["next_run_at"] == 460.0
    assert rows[0]["enabled"] == 1

    # Still enabled and not due before its (caught-up) next_run.
    assert sched.due(now=400.0) == []


def test_run_due_fires_recurring_and_stays_enabled(tmp_path):
    sched = CodingScheduler(db_path=_db(tmp_path))
    sid = sched.schedule_recurring(
        "sess-r", "beat", interval_seconds=60.0, first_run_at=100.0
    )

    calls: list[tuple[str, str]] = []
    fired = sched.run_due(now=100.0, send=lambda s, m: calls.append((s, m)))
    assert fired == 1
    assert calls == [("sess-r", "beat")]

    rows = sched.list_schedules("sess-r")
    assert rows[0]["enabled"] == 1
    assert rows[0]["next_run_at"] == 160.0
    # Not due again until the next interval.
    assert sched.due(now=159.0) == []
    assert len(sched.due(now=160.0)) == 1


def test_cancel_disables(tmp_path):
    sched = CodingScheduler(db_path=_db(tmp_path))
    sid = sched.schedule_once("sess-3", "cancel me", run_at=100.0)
    assert len(sched.due(now=150.0)) == 1

    sched.cancel(sid)
    assert sched.due(now=150.0) == []

    rows = sched.list_schedules("sess-3")
    assert len(rows) == 1
    assert rows[0]["enabled"] == 0


def test_persistence_across_instances(tmp_path):
    db = _db(tmp_path)
    sched1 = CodingScheduler(db_path=db)
    sid = sched1.schedule_once("sess-4", "persist", run_at=200.0)

    # A brand-new instance on the same db_path still sees the schedule.
    sched2 = CodingScheduler(db_path=db)
    rows = sched2.list_schedules()
    assert len(rows) == 1
    assert rows[0]["id"] == sid
    assert rows[0]["session_id"] == "sess-4"
    assert rows[0]["message"] == "persist"
    assert len(sched2.due(now=250.0)) == 1


def test_list_schedules_filter_by_session(tmp_path):
    sched = CodingScheduler(db_path=_db(tmp_path))
    sched.schedule_once("a", "m-a", run_at=10.0)
    sched.schedule_once("b", "m-b", run_at=20.0)

    assert {r["session_id"] for r in sched.list_schedules()} == {"a", "b"}
    only_a = sched.list_schedules("a")
    assert len(only_a) == 1
    assert only_a[0]["session_id"] == "a"
