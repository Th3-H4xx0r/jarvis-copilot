"""The weekly recap of the coding agents' work (after coucou's weekly recap,
github.com/Louis-CFM/coucou, MIT).

Pure functions over the ``agent_turns`` rows the tracker records and the
approval/question decisions it logs: time is counted with overlapping turns
merged (two agents working at once is one hour of your week, not two), and
days follow the viewer's timezone.
"""
from __future__ import annotations

import datetime as _dt
from typing import Optional

WEEK = 7 * 86400
_WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
RECAP_HOUR_UTC = 13  # Monday morning in the Americas, afternoon in Europe


def _merge(intervals):
    out = []
    for a, b in sorted(intervals):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def _minutes(intervals) -> int:
    return int(round(sum(b - a for a, b in _merge(intervals)) / 60))


def _split_by_day(a: float, b: float, offset: float):
    """Pieces of [a, b) per local day: [(date, seconds)]."""
    out = []
    while a < b:
        local = _dt.datetime.fromtimestamp(a + offset, tz=_dt.timezone.utc)
        midnight = local.replace(hour=0, minute=0, second=0, microsecond=0) + _dt.timedelta(days=1)
        end = min(b, midnight.timestamp() - offset)
        out.append((local.date(), end - a))
        a = end
    return out


def _top(groups: dict, name: str) -> Optional[dict]:
    if not groups:
        return None
    best = max(groups.items(), key=lambda kv: (_minutes(kv[1]), kv[0]))
    minutes = _minutes(best[1])
    return {name: best[0], "minutes": minutes} if minutes > 0 else None


def build_recap(turns, decisions, *, now: float, days: int = 7, tz_offset_min: int = 0) -> dict:
    start = now - days * 86400
    offset = tz_offset_min * 60.0
    spans, by_agent, by_project, by_key, keys_meta = [], {}, {}, {}, {}
    totals = {"files": 0, "added": 0, "removed": 0, "commands": 0}
    for t in turns or []:
        a = max(float(t.get("started_at") or 0), start)
        b = min(float(t.get("ended_at") or 0), now)
        if b <= a:
            continue
        spans.append((a, b))
        by_agent.setdefault(t.get("agent") or "claude", []).append((a, b))
        by_project.setdefault(t.get("project") or "session", []).append((a, b))
        key = t.get("key") or ""
        by_key.setdefault(key, []).append((a, b))
        keys_meta.setdefault(key, {"project": t.get("project") or "session", "agent": t.get("agent") or "claude"})
        for k in totals:
            totals[k] += int(t.get(k) or 0)

    days_secs: dict = {}
    for a, b in _merge(spans):
        for day, secs in _split_by_day(a, b, offset):
            days_secs[day] = days_secs.get(day, 0) + secs
    busiest = None
    if days_secs:
        day, secs = max(days_secs.items(), key=lambda kv: (kv[1], kv[0]))
        busiest = {"date": day.isoformat(), "weekday": _WEEKDAYS[day.weekday()], "minutes": int(round(secs / 60))}

    longest = None
    if by_key:
        key, iv = max(by_key.items(), key=lambda kv: (_minutes(kv[1]), kv[0]))
        longest = {"key": key, **keys_meta[key], "minutes": _minutes(iv)}

    approved = denied = answered = 0
    for d in decisions or []:
        decision, kind = d.get("decision"), d.get("kind")
        if kind == "ask":
            answered += decision == "answer"
        elif decision in ("allow", "always"):
            approved += 1
        elif decision == "deny":
            denied += 1

    return {"since": start, "until": now, "days": days,
            "minutes": _minutes(spans), "sessions": len(by_key), **totals,
            "approved": approved, "denied": denied, "answered": answered,
            "top_agent": _top(by_agent, "agent"), "top_project": _top(by_project, "project"),
            "busiest_day": busiest, "longest_session": longest}


def _hours(minutes: int) -> str:
    h, m = divmod(int(minutes), 60)
    if h and m:
        return f"{h}h {m}m"
    return f"{h}h" if h else f"{m}m"


def summary_line(recap: dict) -> Optional[str]:
    if not recap or not recap.get("minutes"):
        return None
    n = recap.get("sessions", 0)
    parts = [f"{_hours(recap['minutes'])} of agent time", f"{n} session{'s' if n != 1 else ''}"]
    if recap.get("files"):
        parts.append(f"{recap['files']} files changed")
    top = recap.get("top_project")
    if top:
        parts.append(f"mostly {top['project']}")
    return " · ".join(parts)


def _this_monday_recap_time(now: float) -> float:
    d = _dt.datetime.fromtimestamp(now, tz=_dt.timezone.utc)
    monday = (d - _dt.timedelta(days=d.weekday())).replace(hour=RECAP_HOUR_UTC, minute=0, second=0,
                                                           microsecond=0)
    return monday.timestamp()


def recap_due(now: float, last_sent: Optional[float]) -> bool:
    """True once each Monday from RECAP_HOUR_UTC (UTC) until it has been sent."""
    if _dt.datetime.fromtimestamp(now, tz=_dt.timezone.utc).weekday() != 0:
        return False
    due_at = _this_monday_recap_time(now)
    return now >= due_at and (last_sent is None or last_sent < due_at)
