"""Quit habits: streaks, relapses per local day and month, and the goal."""
from datetime import datetime, timezone

import pytest

from jarvis_health import habits

NOW = datetime(2026, 10, 14, 20, 0, tzinfo=timezone.utc)          # 13:00 in Los Angeles
LA = "America/Los_Angeles"


def _habit(**goal):
    return {"id": "scroll", "name": "Doomscrolling", "started_at": "2026-10-01T07:00:00Z",
            "timezone": LA, "goal": {"streak_days": goal.get("streak_days"), "limit": goal.get("limit")}}


def _r(at):
    return {"habit": "scroll", "uid": at, "at": at, "tz": LA}


def _utc(*args):
    return datetime(*args, tzinfo=timezone.utc)


def test_with_no_relapse_the_streak_runs_from_the_quit_date():
    s = habits.summary(_habit(streak_days=30), [], NOW)
    assert s["since"] == "2026-10-01T07:00:00Z"
    assert s["current_streak_seconds"] == int((NOW - _utc(2026, 10, 1, 7)).total_seconds())
    assert s["last_relapse_at"] is None and s["total"] == 0
    assert 0.4 < s["goal"]["streak_progress"] < 0.5          # ~13.5 of 30 days


def test_the_streak_restarts_at_the_last_relapse_and_the_longest_is_kept():
    s = habits.summary(_habit(), [_r("2026-10-12T20:00:00Z"), _r("2026-10-05T07:00:00Z")], NOW)
    assert s["since"] == "2026-10-12T20:00:00Z"
    assert s["last_relapse_at"] == "2026-10-12T20:00:00Z"
    assert s["current_streak_seconds"] == 2 * 86400
    assert s["longest_streak_seconds"] == int((_utc(2026, 10, 12, 20) - _utc(2026, 10, 5, 7)).total_seconds())


def test_a_quit_date_after_the_last_relapse_starts_the_streak_there():
    habit = _habit()
    habit["started_at"] = "2026-10-13T20:00:00Z"
    s = habits.summary(habit, [_r("2026-10-05T07:00:00Z")], NOW)
    assert s["since"] == "2026-10-13T20:00:00Z"
    assert s["current_streak_seconds"] == 86400


def test_days_and_months_are_the_habits_local_ones():
    # 23:30 on Sep 30 in Los Angeles is Oct 1 06:30 UTC: it belongs to September there.
    rel = [_r("2026-10-01T06:30:00Z"), _r("2026-10-14T08:00:00Z"), _r("2026-10-14T19:00:00Z")]
    s = habits.summary(_habit(), rel, NOW)
    assert s["today"] == 2            # Oct 14 01:00 and 12:00 local
    assert s["this_month"] == 2
    assert s["last_month"] == 1
    assert s["last_7_days"] == 2
    days = habits.daily(_habit(), rel, 14, NOW)
    assert len(days) == 14 and days[0] == {"date": "2026-10-01", "count": 0}
    assert days[-1] == {"date": "2026-10-14", "count": 2}
    assert sum(d["count"] for d in days) == 2


def test_limits_report_what_is_used_and_whether_it_is_within():
    rel = [_r("2026-10-14T16:00:00Z"), _r("2026-10-14T17:00:00Z")]
    daily_limit = habits.summary(_habit(limit={"per": "day", "count": 1}), rel, NOW)["goal"]["limit"]
    assert daily_limit == {"per": "day", "count": 1, "used": 2, "within": False}
    monthly = habits.summary(_habit(limit={"per": "month", "count": 3}), rel, NOW)["goal"]["limit"]
    assert monthly == {"per": "month", "count": 3, "used": 2, "within": True}
    assert habits.summary(_habit(), rel, NOW)["goal"]["limit"] is None


def test_clean_trims_stamps_and_keeps_created_at():
    raw = {"id": "scroll", "name": "  Doomscrolling ", "started_at": "2026-10-01T07:00:00Z", "timezone": LA,
           "goal": {"streak_days": 30, "limit": {"per": "month", "count": 3}}}
    first = habits.clean(raw, NOW, None)
    assert first["name"] == "Doomscrolling" and first["created_at"] == "2026-10-14T20:00:00Z"
    kept = {**first, "created_at": "2026-10-02T00:00:00Z"}
    again = habits.clean({**raw, "goal": {"streak_days": 30}}, NOW, kept)
    assert again["created_at"] == "2026-10-02T00:00:00Z"
    assert again["goal"] == {"streak_days": 30, "limit": None}     # a goal is replaced whole


def test_clean_keeps_the_fields_a_change_leaves_out():
    first = habits.clean({"id": "scroll", "name": "Doomscrolling", "started_at": "2026-10-01T07:00:00Z",
                          "timezone": LA, "goal": {"streak_days": 30}}, NOW, None)
    renamed = habits.clean({"id": "scroll", "name": "Scrolling"}, NOW, first)
    assert renamed["name"] == "Scrolling"
    assert renamed["goal"] == first["goal"] and renamed["started_at"] == first["started_at"]
    assert renamed["timezone"] == LA


def test_a_new_habit_without_a_quit_date_starts_now():
    assert habits.clean({"id": "x", "name": "Vape"}, NOW, None)["started_at"] == "2026-10-14T20:00:00Z"


@pytest.mark.parametrize("bad", [
    {"name": ""}, {"name": "x" * 81}, {"timezone": "Mars/Base"},
    {"started_at": "2026-10-20T00:00:00Z"}, {"started_at": "yesterday"},
    {"goal": {"streak_days": 0}}, {"goal": {"streak_days": True}}, {"goal": {"streak_days": 4000}},
    {"goal": {"limit": {"per": "week", "count": 1}}}, {"goal": {"limit": {"per": "day", "count": -1}}},
    {"goal": "lots"},
])
def test_clean_refuses_what_it_cannot_store(bad):
    raw = {"id": "scroll", "name": "Doomscrolling", "started_at": "2026-10-01T07:00:00Z", "timezone": LA, **bad}
    with pytest.raises(ValueError):
        habits.clean(raw, NOW, None)


def test_new_id_is_a_registry_safe_slug():
    made = habits.new_id("No Instagram!!")
    assert made.startswith("no-instagram-") and len(made) <= 55
    assert habits.new_id("😀").startswith("habit-")
