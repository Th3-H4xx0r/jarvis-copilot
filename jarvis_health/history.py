"""History: every metric over a week, a month, six months or a year.

A history day is the same sleep-to-sleep day the Health tab's pills show
(`window.cycle`, today `window.today`), summarised to one number set, so a
day in history always reads what that day's pill reads. Weeks and months
are the mean of the days actually measured — an unmeasured day is a gap,
never a zero. The highlight is a rule-based sentence, not a model call, so
the screen opens instantly.
"""
from __future__ import annotations

import calendar
from dataclasses import dataclass
from datetime import date as Date, datetime, timedelta
from statistics import mean
from typing import Callable, Optional

from .baselines import resting_hr, sleeping_hrv
from .metrics import STAGE_AWAKE, STAGE_DEEP, STAGE_LIGHT, STAGE_REM, from_json, parse_instant
from .sleep_debt import NIGHTS, goal_of, slept
from .window import cycle, today

#: range → (bucket unit, bucket count)
RANGES = {"W": ("day", 7), "M": ("day", 30), "6M": ("week", 26), "Y": ("month", 12)}

#: What "the last …" and "the … before" say for each range.
_SPANS = {"W": ("the last 7 days", "the 7 days before"), "M": ("the last 30 days", "the 30 days before"),
          "6M": ("the last 6 months", "the 6 months before"), "Y": ("the last year", "the year before")}


@dataclass(frozen=True)
class Metric:
    title: str
    #: Summary key the bucket value is read from.
    value: str
    #: How the phone formats it: steps, bpm, percent, ms, celsius, minutes, level, score, count.
    kind: str
    headline: str
    #: For the highlight: "your <noun> over the last 7 days was …".
    noun: str
    low: Optional[str] = None
    high: Optional[str] = None


METRICS: dict[str, Metric] = {
    "battery": Metric("Body Battery", "battery_end", "level", "Range", "average end-of-day Body Battery",
                      "battery_low", "battery_high"),
    "steps": Metric("Steps", "steps", "steps", "Daily average", "average steps a day"),
    "sleep": Metric("Sleep", "asleep", "minutes", "Average asleep", "average sleep"),
    "sleep_debt": Metric("Sleep debt", "sleep_debt", "minutes", "Owed now", "sleep debt"),
    "heart_rate": Metric("Heart rate", "hr_avg", "bpm", "Range", "average heart rate", "hr_min", "hr_max"),
    "spo2": Metric("Blood oxygen", "spo2_avg", "percent", "Average", "average blood oxygen", "spo2_min"),
    "hrv": Metric("HRV", "hrv", "ms", "Average", "average HRV"),
    "stress": Metric("Stress", "stress_avg", "score", "Average", "average stress"),
    "temperature": Metric("Temperature", "temperature_avg", "celsius", "Average", "average temperature"),
}

# ── day summaries ──────────────────────────────────────────────────────────

#: (registry path, space, date) → summary, for days old enough not to change.
_memo: dict[tuple, dict] = {}


def _memo_key(store, date: str) -> tuple:
    return (str(getattr(store._registry, "path", id(store._registry))), store.space_id, date)


def forget(store, date: str) -> None:
    """A stored day changes its own summary and its neighbours' (their windows meet)."""
    d = Date.fromisoformat(date)
    for k in (-1, 0, 1):
        _memo.pop(_memo_key(store, (d + timedelta(days=k)).isoformat()), None)


def _mean(values) -> Optional[float]:
    values = [v for v in values if v is not None]
    return round(mean(values), 1) if values else None


def day_summary(store, date: str, now: str, window: Optional[dict] = None) -> dict:
    """One number set for a day, from its sleep-to-sleep window."""
    w = window or cycle(store, date, now)
    day = from_json(w["day"]) if w.get("day") else None
    out: dict = {"date": date}
    stats = w.get("stats") or {}
    curve = [p["level"] for p in (w.get("battery") or {}).get("curve") or []]
    out["battery_high"] = max(curve) if curve else None
    out["battery_low"] = min(curve) if curve else None
    out["battery_end"] = curve[-1] if curve else None
    if day is None:
        return out
    for key in ("steps", "kilocalories", "distance_meters", "active_minutes", "hr_avg", "hr_min", "hr_max",
                "stress_avg", "temperature_avg"):
        out[key] = stats.get(key)
    out["spo2_min"] = stats.get("spo2_low")
    out["spo2_avg"] = _mean(day.spo2.nonzero()) if day.spo2 else None
    out["resting_hr"] = resting_hr(day)
    out["hrv"] = sleeping_hrv(day) or stats.get("hrv_avg")
    out["asleep"] = slept(day)
    night = day.main_sleep
    if night is not None:
        out.update(deep=night.stage_minutes(STAGE_DEEP), light=night.stage_minutes(STAGE_LIGHT),
                   rem=night.stage_minutes(STAGE_REM), awake=night.stage_minutes(STAGE_AWAKE))
    return out


def _summaries(store, dates: list[str], now: str, today_window: dict) -> dict[str, dict]:
    """Summaries for `dates`, reusing old ones; today and yesterday are always fresh."""
    fresh_after = (Date.fromisoformat(today_window["date"]) - timedelta(days=1)).isoformat()
    stored = set(store.dates(100_000))
    first = min(stored) if stored else None
    out = {}
    for date in dates:
        # History starts at the first day a wearable stored — not the sliver
        # of the evening before it that the first night's window reaches into.
        if first is None or date < first:
            out[date] = {"date": date}
            continue
        if date > today_window["date"]:
            out[date] = {"date": date}
            continue
        key = _memo_key(store, date)
        if date < fresh_after and key in _memo:
            out[date] = _memo[key]
            continue
        summary = day_summary(store, date, now, today_window if date == today_window["date"] else None)
        if date < fresh_after:
            _memo[key] = summary
        out[date] = summary
    return out


def _with_sleep_debt(days: list[dict], goal: int) -> None:
    """Each day's running debt over its seven nights, as the sleep-debt card counts it."""
    for i, summary in enumerate(days):
        window = days[max(0, i - NIGHTS + 1): i + 1]
        if not any(d.get("asleep") is not None for d in window) or summary.get("asleep") is None:
            summary["sleep_debt"] = None
            continue
        running = 0
        for d in window:
            if d.get("asleep") is not None:
                running = max(0, running + goal - d["asleep"])
        summary["sleep_debt"] = running


# ── buckets ────────────────────────────────────────────────────────────────

def _periods(range_: str, end: Date) -> list[tuple[Date, Date]]:
    unit, count = RANGES[range_]
    if unit == "day":
        return [(end - timedelta(days=n), end - timedelta(days=n)) for n in range(count - 1, -1, -1)]
    if unit == "week":
        monday = end - timedelta(days=end.weekday())
        return [(monday - timedelta(weeks=n), monday - timedelta(weeks=n) + timedelta(days=6))
                for n in range(count - 1, -1, -1)]
    periods = []
    year, month = end.year, end.month
    for _ in range(count):
        periods.append((Date(year, month, 1), Date(year, month, calendar.monthrange(year, month)[1])))
        year, month = (year, month - 1) if month > 1 else (year - 1, 12)
    return list(reversed(periods))


def _dates(first: Date, last: Date) -> list[str]:
    return [(first + timedelta(days=k)).isoformat() for k in range((last - first).days + 1)]


def _bucket(metric: str, days: list[dict], start: Date, end: Date) -> dict:
    m = METRICS[metric]
    measured = [d for d in days if d.get(m.value) is not None]
    out = {"start": start.isoformat(), "end": end.isoformat(), "days": len(measured),
           "value": None, "low": None, "high": None}
    if not measured:
        return out
    if metric == "sleep_debt":
        out["value"] = measured[-1][m.value]
    else:
        out["value"] = _mean(d[m.value] for d in measured)
    if m.low:
        lows = [d[m.low] for d in measured if d.get(m.low) is not None]
        out["low"] = min(lows) if lows else None
    if m.high:
        highs = [d[m.high] for d in measured if d.get(m.high) is not None]
        out["high"] = max(highs) if highs else None
    if metric == "sleep":
        out["stages"] = {s: _mean(d.get(s) for d in measured) or 0 for s in ("deep", "light", "rem", "awake")}
    return out


# ── stats, headline, highlight ─────────────────────────────────────────────

def _values(days: list[dict], key: str) -> list[float]:
    return [d[key] for d in days if d.get(key) is not None]


def _stat(label: str, value, kind: str) -> dict:
    return {"label": label, "value": value, "kind": kind}


def _stats(metric: str, days: list[dict], goal: int) -> list[dict]:
    m = METRICS[metric]
    v = _values(days, m.value)
    avg, hi, lo = _mean(v), (max(v) if v else None), (min(v) if v else None)
    if metric == "battery":
        highs = _values(days, "battery_high")
        out = [_stat("Average end", avg, "level"), _stat("Highest", max(highs) if highs else None, "level"),
               _stat("Lowest", min(_values(days, "battery_low")) if highs else None, "level"),
               _stat("Days reaching High", sum(1 for h in highs if h >= 76), "count")]
    elif metric == "steps":
        out = [_stat("Total", int(sum(v)) if v else None, "steps"), _stat("Daily average", avg, "steps"),
               _stat("Best day", hi, "steps"),
               _stat("Calories", sum(_values(days, "kilocalories")) or None, "kcal"),
               _stat("Distance", sum(_values(days, "distance_meters")) or None, "meters"),
               _stat("Active", sum(_values(days, "active_minutes")) or None, "minutes")]
    elif metric == "sleep":
        out = [_stat("Average", avg, "minutes"), _stat("Longest", hi, "minutes"), _stat("Shortest", lo, "minutes"),
               _stat("Average deep", _mean(_values(days, "deep")), "minutes"),
               _stat("Average REM", _mean(_values(days, "rem")), "minutes")]
    elif metric == "sleep_debt":
        asleep = _values(days, "asleep")
        out = [_stat("Owed now", v[-1] if v else None, "minutes"), _stat("Highest", hi, "minutes"),
               _stat("Short nights", sum(1 for a in asleep if a < goal), "count"), _stat("Goal", goal, "minutes")]
    elif metric == "heart_rate":
        out = [_stat("Average", avg, "bpm"), _stat("Resting", _mean(_values(days, "resting_hr")), "bpm"),
               _stat("Lowest", min(_values(days, "hr_min")) if _values(days, "hr_min") else None, "bpm"),
               _stat("Highest", max(_values(days, "hr_max")) if _values(days, "hr_max") else None, "bpm")]
    elif metric == "spo2":
        lows = _values(days, "spo2_min")
        out = [_stat("Average", avg, "percent"), _stat("Lowest", min(lows) if lows else None, "percent"),
               _stat("Days below 95%", sum(1 for x in lows if x < 95), "count")]
    elif metric == "hrv":
        out = [_stat("Average", avg, "ms"), _stat("Highest", hi, "ms"), _stat("Lowest", lo, "ms")]
    elif metric == "stress":
        out = [_stat("Average", avg, "score"), _stat("Calmest day", lo, "score"), _stat("Most stressed", hi, "score")]
    else:
        out = [_stat("Average", avg, "celsius"), _stat("Highest", hi, "celsius"), _stat("Lowest", lo, "celsius")]
    return out + [_stat("Days measured", len(v), "count")]


def _headline(metric: str, days: list[dict]) -> dict:
    m = METRICS[metric]
    v = _values(days, m.value)
    lows = _values(days, m.low) if m.low else []
    highs = _values(days, m.high) if m.high else []
    value = (v[-1] if v else None) if metric == "sleep_debt" else _mean(v)
    return {"label": m.headline, "value": value, "low": min(lows) if lows else None,
            "high": max(highs) if highs else None, "kind": m.kind}


def _say(value: float, kind: str, unit: str) -> str:
    if kind == "minutes":
        minutes = int(round(value))
        return f"{minutes // 60}h {minutes % 60}m" if minutes >= 60 else f"{minutes}m"
    if kind == "steps":
        return f"{int(round(value)):,}"
    if kind == "bpm":
        return f"{round(value)} bpm"
    if kind == "percent":
        return f"{round(value)}%"
    if kind == "ms":
        return f"{round(value)} ms"
    if kind == "celsius":
        return f"{value * 9 / 5:.1f} °F" if unit == "fahrenheit" else f"{value:.1f} °C"
    return f"{round(value)}"


def _delta(value: float, kind: str, unit: str) -> str:
    if kind == "celsius":
        return f"{value * 9 / 5:.1f} °F" if unit == "fahrenheit" else f"{value:.1f} °C"
    return _say(value, kind, unit)


def _highlight(metric: str, range_: str, current: Optional[float], previous: Optional[float],
               days_so_far: int, unit: str) -> str:
    m = METRICS[metric]
    if current is None:
        name = m.title if m.title.isupper() else m.title.lower()
        return f"No {name} recorded in this range yet."
    if previous is None:
        plural = "day" if days_so_far == 1 else "days"
        return (f"Jarvis Health has {days_so_far} {plural} of history so far — trends appear once there "
                f"is a period to compare.")
    span, before = _SPANS[range_]
    diff = current - previous
    close = abs(diff) < (0.05 if m.kind == "celsius" else 0.5)
    lead = f"Your {m.noun} over {span} was {_say(current, m.kind, unit)}"
    if close:
        return f"{lead}, about the same as {before}."
    word = ("more" if diff > 0 else "less") if m.kind in ("minutes", "steps") else ("higher" if diff > 0 else "lower")
    return f"{lead}, {_delta(abs(diff), m.kind, unit)} {word} than {before}."


def history(store, metric: str, range_: str, end: Optional[str], now: str) -> dict:
    """A metric's buckets over the range ending on `end` (default: today), with stats and a highlight."""
    if metric not in METRICS:
        raise ValueError(f"unknown metric {metric!r}")
    if range_ not in RANGES:
        raise ValueError(f"unknown range {range_!r}")
    settings = store.settings()
    goal = goal_of(settings)
    current_day = today(store, now)
    last = Date.fromisoformat(end or current_day["date"])
    periods = _periods(range_, last)
    span = (periods[-1][1] - periods[0][0]).days + 1
    prev_last = periods[0][0] - timedelta(days=1)
    prev_first = prev_last - timedelta(days=span - 1)

    dates = _dates(prev_first - timedelta(days=NIGHTS - 1), periods[-1][1])
    summaries = _summaries(store, dates, now, current_day)
    ordered = [dict(summaries[d]) for d in dates]
    _with_sleep_debt(ordered, goal)
    by_date = {d["date"]: d for d in ordered}

    def days_in(first: Date, last_: Date) -> list[dict]:
        return [by_date[d] for d in _dates(first, last_) if d in by_date]

    current = days_in(periods[0][0], periods[-1][1])
    before = days_in(prev_first, prev_last)
    head, prev_head = _headline(metric, current), _headline(metric, before)
    days_so_far = len(store.dates(100_000))
    return {
        "metric": metric,
        "range": range_,
        "title": METRICS[metric].title,
        "kind": METRICS[metric].kind,
        "start": periods[0][0].isoformat(),
        "end": periods[-1][1].isoformat(),
        "buckets": [_bucket(metric, days_in(a, b), a, b) for a, b in periods],
        "headline": head,
        "stats": _stats(metric, current, goal),
        "previous": {"average": prev_head["value"], "days": len(_values(before, METRICS[metric].value))},
        "highlight": _highlight(metric, range_, head["value"], prev_head["value"], days_so_far,
                                settings.get("temperature_unit") or "celsius"),
        "days_so_far": days_so_far,
    }
