"""Turn the time words in a question into a window, by rule — no model.

"this weekend", "tomorrow", "last Tuesday", "Oct 25", "tonight"… all resolve
against *his* clock (the caller passes an aware ``now`` in his zone), so a
question asked at 22:30 on Friday means Saturday by "tomorrow", not Sunday.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, time as dtime, timedelta
from typing import Optional

_DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
_MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], start=1)}
_PAST = re.compile(r"\b(did|was|were|went|had|said|told|talked|happened|ago|spent|ate|met)\b")
_MONTH_RE = (r"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|"
             r"sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)")


@dataclass
class TimeWindow:
    start: float
    end: float
    label: str
    future: bool


def _day_start(d: datetime) -> datetime:
    return datetime.combine(d.date(), dtime(0, 0), tzinfo=d.tzinfo)


def _span(start: datetime, end_day: datetime, label: str, now: datetime) -> TimeWindow:
    """From ``start`` to the last instant of ``end_day``'s date."""
    end = (_day_start(end_day) + timedelta(days=1)).timestamp() - 0.001
    return TimeWindow(start.timestamp(), end, label, end > now.timestamp())


def _hours(day: datetime, h0: int, h1: int, label: str, now: datetime) -> TimeWindow:
    start = _day_start(day) + timedelta(hours=h0)
    end = _day_start(day) + timedelta(hours=h1)
    return TimeWindow(start.timestamp(), end.timestamp() - 0.001, label, end > now)


def _weekend(now: datetime, offset_weeks: int) -> TimeWindow:
    today = _day_start(now)
    wd = now.weekday()
    in_weekend = wd in (5, 6) or (wd == 4 and now.hour >= 17)
    friday = today - timedelta(days=wd - 4) if in_weekend else today + timedelta(days=(4 - wd) % 7)
    friday += timedelta(weeks=offset_weeks)
    start = friday + timedelta(hours=17)
    return _span(start, friday + timedelta(days=2), "weekend", now)


def window(text: str, now: datetime) -> Optional[TimeWindow]:
    t = " ".join((text or "").lower().split())
    if not t:
        return None
    today = _day_start(now)
    past = bool(_PAST.search(t))

    if re.search(r"\blast night\b", t):
        y = today - timedelta(days=1)
        return TimeWindow((y + timedelta(hours=17)).timestamp(),
                          (today + timedelta(hours=4)).timestamp(), "last night", False)
    if re.search(r"\btonight\b", t):
        return _hours(today, 17, 24, "tonight", now)
    if re.search(r"\bthis morning\b", t):
        return _hours(today, 5, 12, "this morning", now)
    if re.search(r"\bthis afternoon\b", t):
        return _hours(today, 12, 17, "this afternoon", now)
    if re.search(r"\bthis evening\b", t):
        return _hours(today, 17, 24, "this evening", now)
    if re.search(r"\b(day after tomorrow)\b", t):
        d = today + timedelta(days=2)
        return _span(d, d, "day after tomorrow", now)
    if re.search(r"\btomorrow\b", t):
        d = today + timedelta(days=1)
        return _span(d, d, "tomorrow", now)
    if re.search(r"\byesterday\b", t):
        d = today - timedelta(days=1)
        return _span(d, d, "yesterday", now)
    if re.search(r"\btoday\b", t):
        return _span(today, today, "today", now)
    if re.search(r"\bnext weekend\b", t):
        return _weekend(now, 1)
    if re.search(r"\blast weekend\b", t):
        return _weekend(now, -1)
    if re.search(r"\b(this|the|on the) weekend\b", t):
        return _weekend(now, 0)
    m = re.search(r"\b(this|next|last) week\b", t)
    if m:
        monday = today - timedelta(days=now.weekday())
        monday += timedelta(weeks={"this": 0, "next": 1, "last": -1}[m.group(1)])
        return _span(monday, monday + timedelta(days=6), f"{m.group(1)} week", now)
    m = re.search(r"\bin (\d{1,2}) days?\b", t)
    if m:
        d = today + timedelta(days=int(m.group(1)))
        return _span(d, d, m.group(0), now)
    m = re.search(r"\b(\d{1,2}) days? ago\b", t) or re.search(r"\b(a) week ago\b", t)
    if m:
        n = 7 if m.group(1) == "a" else int(m.group(1))
        d = today - timedelta(days=n)
        return _span(d, d, m.group(0), now)
    m = re.search(r"\b(last|next|this)?\s*(monday|tuesday|wednesday|thursday|friday|saturday|sunday)s?\b", t)
    if m:
        target = _DAYS.index(m.group(2))
        mod = m.group(1)
        if mod == "last" or (mod is None and past):
            back = (now.weekday() - target) % 7 or 7
            d = today - timedelta(days=back)
        else:
            ahead = (target - now.weekday()) % 7
            if mod == "next" and ahead == 0:
                ahead = 7
            d = today + timedelta(days=ahead)
        return _span(d, d, m.group(0).strip(), now)
    m = (re.search(rf"\b{_MONTH_RE}\.?\s+(\d{{1,2}})(?:st|nd|rd|th)?\b", t)
         or re.search(rf"\b(\d{{1,2}})(?:st|nd|rd|th)?\s+(?:of\s+)?{_MONTH_RE}\b", t))
    if m:
        a, b = m.group(1), m.group(2)
        month_word, day = (a, int(b)) if not a.isdigit() else (b, int(a))
        month = _MONTHS[month_word[:3]]
        try:
            d = today.replace(month=month, day=day)
        except ValueError:
            return None
        if past and d > today:
            d = d.replace(year=d.year - 1)  # "what did we do on April 10" looks back
        elif not past and (today - d).days > 180:
            d = d.replace(year=d.year + 1)
        return _span(d, d, m.group(0), now)
    m = re.search(r"\bthe (\d{1,2})(?:st|nd|rd|th)\b", t)
    if m:
        try:
            d = today.replace(day=int(m.group(1)))
        except ValueError:
            return None
        if past and d > today:  # "what happened on the 25th" — last month's
            month = (d.month - 2) % 12 + 1
            try:
                d = d.replace(year=d.year - (1 if month == 12 else 0), month=month)
            except ValueError:
                return None
        elif d < today and not past:
            month = d.month % 12 + 1
            try:
                d = d.replace(year=d.year + (1 if month == 1 else 0), month=month)
            except ValueError:  # "the 31st" asked in a month followed by a short one
                return None
        return _span(d, d, m.group(0), now)
    return None
