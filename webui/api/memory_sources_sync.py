"""Every source into the memory map (Project 2).

Every 30 minutes (and right after the phone sends a calendar snapshot) the web
server turns what it already keeps into short memory summaries — never raw
text — one per stable source key, so a re-sync of the same thing is a no-op
and a changed one replaces the old memory. The map pass then links them to
people, places and events like any other memory:

- calendar:<key>   each phone-calendar event (event times set directly);
                   future events gone from the phone are forgotten
- reminder:<key>   each open iOS reminder; completed ones are forgotten
- email:<job>:<run> what the email monitor reported, when it reported something
- cron:<job>:<run>  other integrations' reports (flights, house watch …)
- health:day:<date> the day's health line (wake, Body Battery, workouts …)
- location:day:<date> the places he was that day
- dashcam:drive:<id> each drive
"""
from __future__ import annotations

import hashlib
import json
import logging
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Optional

logger = logging.getLogger(__name__)

EVERY_S = 30 * 60
LOOKBACK_DAYS = 7
CUT = 600

_kick = threading.Event()
_started = threading.Event()


def _memory():
    from plugins.memory.jarvis_memory import external
    return external


def _key(*parts) -> str:
    return hashlib.sha1("\x1e".join(str(p) for p in parts).encode("utf-8")).hexdigest()[:16]


def _day(ts: float, zone) -> str:
    d = datetime.fromtimestamp(ts, zone)
    return f"{d:%a} {d.day} {d:%b}"


def _clock(ts: float, zone) -> str:
    return datetime.fromtimestamp(ts, zone).strftime("%I:%M %p").lstrip("0")


# ── calendar + reminders (the phone's snapshot) ──────────────────────────
def _calendar_line(ev: dict, zone) -> Optional[tuple]:
    from api.brief_sources import _parse_iso
    title = str(ev.get("title") or "").strip()
    start = _parse_iso(ev.get("start_iso"), zone)
    if not title or start is None:
        return None
    end = _parse_iso(ev.get("end_iso"), zone)
    if ev.get("all_day"):
        last = (end - 1) if end and end - start > 86400 else start
        when = _day(start, zone) if _day(last, zone) == _day(start, zone) \
            else f"{_day(start, zone)} – {_day(last, zone)}"
    else:
        when = f"{_day(start, zone)} {_clock(start, zone)}"
    body = f"Calendar: {title}, {when}" + (f" @ {ev['location']}" if ev.get("location") else "")
    return f"calendar:{_key(title.lower(), ev.get('start_iso'))}", body, start, end


def _sync_calendar(now: float, zone) -> int:
    from api.brief_sources import snapshot
    mem = _memory()
    snap = snapshot()
    added, seen = 0, set()
    for ev in snap.get("calendar") or []:
        line = _calendar_line(ev, zone)
        if line is None:
            continue
        source, body, start, end = line
        seen.add(source)
        before = mem.memories(source, limit=1)
        if mem.upsert(body, source=source, tags="calendar", created_at=start,
                      event_start=start, event_end=end or start, kind="event") and not before:
            added += 1
    if snap.get("calendar") is not None:
        # An event still ahead that the phone no longer has was moved or cancelled.
        for m in mem.memories("calendar:", limit=1000):
            source = m["source"]
            if source not in seen and m["created_at"] > now:
                mem.forget(source_prefix=source)
    return added


def _sync_reminders(zone) -> int:
    from api.brief_sources import _parse_iso, snapshot
    mem = _memory()
    snap = snapshot()
    if snap.get("reminders") is None:
        return 0
    added, seen = 0, set()
    for r in snap.get("reminders") or []:
        title = str(r.get("title") or "").strip()
        if not title:
            continue
        source = f"reminder:{_key(title.lower(), r.get('list'))}"
        seen.add(source)
        due = _parse_iso(r.get("due_iso"), zone)
        bits = [r["list"]] if r.get("list") else []
        if due:
            bits.append(f"due {_day(due, zone)}")
        body = f"Reminder: {title}" + (f" ({', '.join(bits)})" if bits else "")
        before = mem.memories(source, limit=1)
        if mem.upsert(body, source=source, tags="reminder", event_start=due, kind="plan") and not before:
            added += 1
    for m in mem.memories("reminder:", limit=1000):
        if m["source"] not in seen:  # done or deleted on the phone
            mem.forget(source_prefix=m["source"])
    return added


# ── email + other integrations (cron outputs) ────────────────────────────
def _email_jobs() -> list:
    from api.brief_sources import _email_jobs as jobs
    return jobs()


def _other_jobs() -> list:
    try:
        from cron.jobs import list_jobs
        return [j for j in list_jobs(include_disabled=False)
                if j.get("integration") and j.get("integration") != "email-monitor"]
    except Exception:
        return []


def _sync_runs(prefix: str, jobs: list, now: float, zone) -> int:
    from api.brief_sources import _home, _response_lines
    mem = _memory()
    quiet = ("nothing", "no new", "no email", "no activity", "no messages", "no changes", "no updates")
    added = 0
    cutoff = now - LOOKBACK_DAYS * 86400
    for job in jobs:
        folder = _home() / "cron" / "output" / str(job.get("id"))
        try:
            runs = [p for p in folder.glob("*.md") if p.stat().st_mtime >= cutoff]
        except Exception:
            continue
        for path in runs:
            source = f"{prefix}:{job.get('id')}:{path.stem}"
            if mem.memories(source, limit=1):
                continue
            lines = _response_lines(path.read_text(encoding="utf-8", errors="ignore"))
            if not lines or any(q in lines[0].lower() for q in quiet):
                continue
            at = path.stat().st_mtime
            body = f"{job.get('name') or prefix}, {_day(at, zone)}: " + " ".join(lines)
            if len(body) > CUT:
                body = body[:CUT].rsplit(" ", 1)[0] + " …"
            if mem.upsert(body, source=source, tags=prefix, created_at=at):
                added += 1
    return added


def _sync_fresh_inbox(now: float, zone) -> int:
    from api.brief_sources import _fresh_inbox_lines
    mem = _memory()
    added = 0
    for line in _fresh_inbox_lines():
        source = f"email:fresh:{_key(line)}"
        if mem.memories(source, limit=1):
            continue
        if mem.upsert(f"Email, {_day(now, zone)}: {line}", source=source, tags="email", created_at=now):
            added += 1
    return added


# ── health, places, drives ───────────────────────────────────────────────
def _health_line(ctx) -> Optional[str]:
    from api.brief_sources import health_source
    text = health_source(ctx)
    return text.removeprefix("Health today: ") if text else None


def _places(day: datetime, zone) -> List[str]:
    """Distinct places (address, shortened) the phone reported on ``day``."""
    from api.brief_sources import _phone_id
    from api.config import STATE_DIR
    device = _phone_id()
    if not device:
        return []
    path = Path(STATE_DIR) / "location_history" / f"{device}.jsonl"
    start = datetime(day.year, day.month, day.day, tzinfo=zone).timestamp()
    end = start + 86400
    out: List[str] = []
    try:
        with open(path, encoding="utf-8") as f:
            for raw in f:
                try:
                    fix = json.loads(raw)
                except ValueError:
                    continue
                if not (start <= float(fix.get("ts") or 0) < end) or not fix.get("address"):
                    continue
                short = ", ".join(str(fix["address"]).split(", ")[:2])
                if short not in out:
                    out.append(short)
    except OSError:
        return []
    return out[:12]


def _drives(since: float) -> list:
    try:
        from api.dashcam_store import store_for_request
        return [d for d in store_for_request().drives() or []
                if float(_ts(d.get("start")) or 0) >= since]
    except Exception:
        return []


def _ts(value) -> Optional[float]:
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _sync_days(now_dt: datetime, zone) -> int:
    from plugins.memory.jarvis_memory.brief import BriefCtx
    mem = _memory()
    added = 0
    today = now_dt.date().isoformat()
    line = _health_line(BriefCtx(now=now_dt, zone=zone, store=None, namespace="global"))
    if line:
        if mem.upsert(f"Health on {_day(now_dt.timestamp(), zone)}: {line}", source=f"health:day:{today}",
                      tags="health", created_at=now_dt.timestamp()):
            added += 1
    for back in (1, 0):
        day = now_dt - timedelta(days=back)
        places = _places(day, zone)
        if places:
            key = day.date().isoformat()
            midday = datetime(day.year, day.month, day.day, 12, tzinfo=zone).timestamp()
            if mem.upsert(f"Places on {_day(midday, zone)}: " + "; ".join(places),
                          source=f"location:day:{key}", tags="location", created_at=midday):
                added += 1
    for d in _drives(now_dt.timestamp() - LOOKBACK_DAYS * 86400):
        start, end = _ts(d.get("start")), _ts(d.get("end"))
        if not start:
            continue
        miles = (d.get("distance_m") or 0) / 1609.34
        span = f"{_clock(start, zone)}–{_clock(end, zone)}" if end else _clock(start, zone)
        a, b = (_clock(start, zone), _clock(end, zone)) if end else (span, "")
        if end and a[-2:] == b[-2:]:  # same AM/PM once: "7:56–8:26 PM"
            span = f"{a[:-3]}–{b}"
        if mem.upsert(f"Drove {miles:.0f} mi on {_day(start, zone)}, {span}",
                      source=f"dashcam:drive:{d.get('id')}", tags="dashcam", created_at=start,
                      event_start=start, event_end=end or start, kind="event"):
            added += 1
    return added


# ── the loop ─────────────────────────────────────────────────────────────
def sync_once(now: Optional[datetime] = None) -> dict:
    from plugins.memory.jarvis_memory import tz
    zone = tz.user_zone()
    now = now or datetime.now(zone)
    ts = now.timestamp()
    counts = {}
    for name, fn in (("calendar", lambda: _sync_calendar(ts, zone)),
                     ("reminders", lambda: _sync_reminders(zone)),
                     ("email", lambda: _sync_runs("email", _email_jobs(), ts, zone) + _sync_fresh_inbox(ts, zone)),
                     ("integrations", lambda: _sync_runs("cron", _other_jobs(), ts, zone)),
                     ("days", lambda: _sync_days(now, zone))):
        try:
            counts[name] = fn()
        except Exception:
            logger.warning("memory sources: %s sync failed", name, exc_info=True)
            counts[name] = 0
    return counts


def kick() -> None:
    """Sync soon (a new phone snapshot arrived)."""
    _kick.set()


def _loop():
    while True:
        _kick.wait(EVERY_S)
        _kick.clear()
        try:
            sync_once()
        except Exception:
            logger.warning("memory sources sync failed", exc_info=True)


def start() -> None:
    if _started.is_set():
        return
    _started.set()
    _kick.set()  # first sync right away
    threading.Thread(target=_loop, daemon=True, name="memory-sources-sync").start()
