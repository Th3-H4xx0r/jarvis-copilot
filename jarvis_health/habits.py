"""Quit habits: how long since the last relapse, relapses per day, the goal.

Pure functions over one habit (its document) and its relapses (records with an
`at`), so the routes, chat and the tests share one set of numbers. Days and
months are the habit's own timezone's — the phone writes its zone on every save.
"""
from __future__ import annotations

import re
import secrets
from datetime import datetime, timedelta, timezone
from typing import Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from jarvis_health.metrics import parse_instant

LIMIT_PERIODS = ("day", "month")
#: A quit date or relapse this far past the server's clock is clock skew, not a mistake.
FUTURE_SLACK = timedelta(minutes=5)


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def instant(value, what: str) -> datetime:
    """A UTC instant from the wire, or a ValueError that says what was wanted."""
    try:
        moment = parse_instant(str(value))
    except (TypeError, ValueError):
        moment = None
    if moment is None or moment.tzinfo is None:
        raise ValueError(f"{what} is a UTC instant: 2026-10-01T07:00:00Z")
    return moment


def _zone(name) -> ZoneInfo:
    try:
        return ZoneInfo(str(name or "UTC"))
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("UTC")


def _whole(value, low: int, high: int, what: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ValueError(f"{what} is a whole number from {low} to {high}")
    return value


def clean_goal(goal) -> dict:
    """A goal as stored: the streak target and the limit, either or both null."""
    if goal is None:
        return {"streak_days": None, "limit": None}
    if not isinstance(goal, dict):
        raise ValueError("a goal is {streak_days, limit}")
    streak = goal.get("streak_days")
    limit = goal.get("limit")
    if streak is not None:
        streak = _whole(streak, 1, 3650, "a streak target")
    if limit is not None:
        if not isinstance(limit, dict) or limit.get("per") not in LIMIT_PERIODS:
            raise ValueError("a limit is {per: day | month, count}")
        limit = {"per": limit["per"], "count": _whole(limit.get("count"), 0, 1000, "a limit")}
    return {"streak_days": streak, "limit": limit}


def clean(raw: dict, now: datetime, existing: Optional[dict]) -> dict:
    """The habit to store: `raw`'s fields over `existing`'s, validated.

    A field `raw` leaves out keeps its old value, so chat can send only what
    changed; a `goal` that is sent replaces the old one whole (the phone's
    encoder leaves a cleared limit out rather than sending null).
    """
    old = existing or {}
    merged = {**old, **{k: v for k, v in raw.items() if k in ("name", "started_at", "timezone", "goal")}}
    name = str(merged.get("name") or "").strip()
    if not 1 <= len(name) <= 80:
        raise ValueError("a habit needs a name of 1–80 characters")
    started = instant(merged.get("started_at") or _iso(now), "the quit date")
    if started > now + FUTURE_SLACK:
        raise ValueError("the quit date can't be in the future")
    zone = str(merged.get("timezone") or "UTC")
    try:
        ZoneInfo(zone)
    except (ZoneInfoNotFoundError, ValueError):
        raise ValueError(f"{zone!r} is not a timezone (e.g. America/Los_Angeles)") from None
    return {"id": raw.get("id") or old.get("id"), "name": name, "started_at": _iso(started), "timezone": zone,
            "goal": clean_goal(merged.get("goal")),
            "created_at": old.get("created_at") or _iso(now), "updated_at": _iso(now)}


def new_id(name) -> str:
    """An id for a habit chat created: its name as a slug, plus a few random letters."""
    slug = re.sub(r"[^a-z0-9]+", "-", str(name or "").lower()).strip("-")[:40].strip("-") or "habit"
    return f"{slug}-{secrets.token_hex(3)}"


def _times(relapses: list[dict]) -> list[datetime]:
    return sorted(parse_instant(r["at"]) for r in relapses)


def summary(habit: dict, relapses: list[dict], now: datetime) -> dict:
    """What a card or chat says about a habit right now."""
    zone = _zone(habit.get("timezone"))
    times = _times(relapses)
    started = parse_instant(habit["started_at"])
    # A quit date moved past the last relapse is a fresh start.
    since = max([started] + times[-1:])
    current = max(0, int((now - since).total_seconds()))
    points = [min([started] + times[:1])] + times
    longest = max([int((b - a).total_seconds()) for a, b in zip(points, points[1:])] + [current])

    today = now.astimezone(zone).date()
    local = [t.astimezone(zone).date() for t in times]
    month = (today.year, today.month)
    previous = (today.year - 1, 12) if today.month == 1 else (today.year, today.month - 1)
    on_day = sum(1 for d in local if d == today)
    this_month = sum(1 for d in local if (d.year, d.month) == month)

    goal = clean_goal(habit.get("goal"))
    streak_days, limit = goal["streak_days"], goal["limit"]
    if limit:
        used = on_day if limit["per"] == "day" else this_month
        limit = {**limit, "used": used, "within": used <= limit["count"]}
    return {
        "since": _iso(since),
        "last_relapse_at": _iso(times[-1]) if times else None,
        "current_streak_seconds": current,
        "longest_streak_seconds": longest,
        "today": on_day,
        "last_7_days": sum(1 for d in local if 0 <= (today - d).days < 7),
        "this_month": this_month,
        "last_month": sum(1 for d in local if (d.year, d.month) == previous),
        "total": len(times),
        "goal": {"streak_days": streak_days,
                 "streak_progress": min(1.0, current / (streak_days * 86400)) if streak_days else None,
                 "limit": limit},
    }


def daily(habit: dict, relapses: list[dict], days: int, now: datetime) -> list[dict]:
    """Relapses per local day for the last `days` days, oldest first."""
    zone = _zone(habit.get("timezone"))
    today = now.astimezone(zone).date()
    counts: dict = {}
    for t in _times(relapses):
        d = t.astimezone(zone).date()
        counts[d] = counts.get(d, 0) + 1
    return [{"date": d.isoformat(), "count": counts.get(d, 0)}
            for d in (today - timedelta(days=i) for i in range(days - 1, -1, -1))]
