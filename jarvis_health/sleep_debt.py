"""Sleep debt: what a week of nights still owes against your sleep goal.

Each night adds the minutes it fell short of the goal; a longer night pays
some back, never below nothing. So the number builds up across the week and
reads as what is still owed. The bands follow the guidance sleep-debt apps
give (Rise: keep it under five hours): under an hour is none, under five is
low, under ten is medium, ten or more is high.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Optional

from .metrics import HealthDay, parse_instant

GOAL = 480
NIGHTS = 7
#: (at least this many minutes owed, band), highest first.
BANDS = ((600, "High"), (300, "Medium"), (60, "Low"), (0, "None"))


def band(minutes: float) -> str:
    return next(name for floor, name in BANDS if minutes >= floor)


def slept(day: Optional[HealthDay]) -> Optional[int]:
    """Minutes asleep on a day — its night and any naps — each counted once.

    A night the ring reported again as it grew, or two copies that overlap,
    is one sleep: the longest copy of anything overlapping is kept. None when
    nothing was recorded (the ring was off, not a night without sleep).
    """
    if day is None or not day.sleep:
        return None
    kept: list = []
    for session in sorted(day.sleep, key=lambda s: s.asleep_minutes, reverse=True):
        if not session.start or not session.end:
            continue
        start, end = parse_instant(session.start), parse_instant(session.end)
        if any(start < parse_instant(k.end) and parse_instant(k.start) < end for k in kept):
            continue
        kept.append(session)
    return sum(s.asleep_minutes for s in kept) if kept else None


def week(store, date: str, goal: int = GOAL) -> dict:
    """The seven nights up to `date`, each with the debt standing after it."""
    from .merge import merged_day

    last = datetime.strptime(date, "%Y-%m-%d").date()
    running = 0
    nights = []
    for back in range(NIGHTS - 1, -1, -1):
        day = (last - timedelta(days=back)).isoformat()
        minutes = slept(merged_day(store, day))
        if minutes is not None:
            running = max(0, running + goal - minutes)
        nights.append({"date": day, "asleep": minutes, "debt": running, "band": band(running)})
    measured = [n["asleep"] for n in nights if n["asleep"] is not None]
    return {
        "goal": goal,
        "debt": running,
        "band": band(running),
        "nights": nights,
        "average": round(sum(measured) / len(measured)) if measured else None,
        "short_nights": sum(1 for m in measured if m < goal),
        "measured": len(measured),
    }


def goal_of(settings: dict) -> int:
    return int(((settings or {}).get("goals") or {}).get("sleep_minutes") or GOAL)
