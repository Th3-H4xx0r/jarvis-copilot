"""The brief's sources that only the web server can reach.

Each returns a short section (or None) for the "now" brief — where he is,
his calendar, health today, inbox, threads waiting on him, home and car,
open tasks — reading what the server already keeps, never calling a model on
the turn's path. ``register_all`` hooks them into the plugin's brief.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Optional

logger = logging.getLogger(__name__)

CAR_TIMEOUT_S = 2.5
INBOX_EVERY_S = 30 * 60


def _home() -> Path:
    from jarviscopilot_constants import get_hermes_home
    return Path(get_hermes_home())


def _ago(ts: float, now: float) -> str:
    mins = max(0, int((now - ts) // 60))
    if mins < 60:
        return f"{mins} min ago"
    if mins < 48 * 60:
        return f"{mins // 60} h ago"
    return f"{mins // 1440} days ago"


def _parse_iso(value, zone) -> Optional[float]:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        d = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (d if d.tzinfo else d.replace(tzinfo=zone)).timestamp()


# ── the phone's context snapshot ─────────────────────────────────────────
def snapshot() -> dict:
    from plugins.memory.jarvis_memory import tz
    try:
        return json.loads(tz.snapshot_path().read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_snapshot(body: dict) -> dict:
    """Validate and atomically store what the phone sent; the brief rebuilds."""
    from plugins.memory.jarvis_memory import brief, tz

    def items(raw, keys):
        out = []
        for it in raw if isinstance(raw, list) else []:
            if isinstance(it, dict) and str(it.get("title") or "").strip():
                out.append({k: it.get(k) for k in keys})
        return out[:300]

    zone_name = str(body.get("tz") or "").strip()
    try:
        from zoneinfo import ZoneInfo
        ZoneInfo(zone_name)
    except Exception:
        zone_name = ""
    snap = {
        "tz": zone_name,
        "calendar": items(body.get("calendar"),
                          ("title", "start_iso", "end_iso", "all_day", "location", "calendar")),
        "reminders": items(body.get("reminders"), ("title", "due_iso", "list")),
        "sent_at": body.get("sent_at"),
        "received_at": time.time(),
    }
    path = tz.snapshot_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(snap), encoding="utf-8")
    os.replace(tmp, path)
    tz.reset_cache()
    brief.mark_dirty()
    try:
        from api import memory_sources_sync
        memory_sources_sync.kick()  # the new calendar/reminders into the map now
    except Exception:
        pass
    return {"calendar": len(snap["calendar"]), "reminders": len(snap["reminders"]), "tz": zone_name}


# ── sources ──────────────────────────────────────────────────────────────
def _phone_id() -> Optional[str]:
    try:
        from api.pairing import list_devices
        phones = [d for d in list_devices() if d.get("kind") == "mobile-ios"]
        phones.sort(key=lambda d: d.get("last_seen") or 0, reverse=True)
        return phones[0]["id"] if phones else None
    except Exception:
        return None


def location_source(ctx) -> Optional[str]:
    device = _phone_id()
    if not device:
        return None
    from api.config import STATE_DIR
    path = Path(STATE_DIR) / "location_history" / f"{device}.jsonl"
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 4096))
            last = f.read().decode("utf-8", "ignore").strip().splitlines()[-1]
        fix = json.loads(last)
    except Exception:
        return None
    where = fix.get("address") or f"{fix.get('lat'):.4f}, {fix.get('lng'):.4f}"
    return f"Where: {where} ({_ago(float(fix.get('ts') or 0), ctx.now.timestamp())})"


def calendar_items(ctx) -> list:
    snap = snapshot()
    start = ctx.now.timestamp() - 86400
    end = (ctx.now + timedelta(days=ctx.horizon_days)).timestamp()
    out = []
    now = ctx.now.timestamp()
    for ev in snap.get("calendar") or []:
        at = _parse_iso(ev.get("start_iso"), ctx.zone)
        if at is None or not (start <= at <= end):
            continue
        ends = _parse_iso(ev.get("end_iso"), ctx.zone)
        if (ends or at) < now and not (ev.get("all_day") and at > now - 86400):
            continue  # over already: not "coming up"
        out.append({"title": ev.get("title"), "start": at, "end": ends,
                    "all_day": bool(ev.get("all_day")), "location": ev.get("location") or ""})
    return out


def health_source(ctx) -> Optional[str]:
    try:
        from jarvis_health.metrics import utc_now
        from jarvis_health.store import HealthStore
        from jarvis_health.window import today
        store = HealthStore()
        out = today(store, utc_now())
    except Exception:
        return None
    bits = []
    if out.get("wake"):
        woke = _parse_iso(out["wake"], ctx.zone)
        if woke:
            bits.append(f"woke {datetime.fromtimestamp(woke, ctx.zone):%I:%M %p}".replace(" 0", " "))
    battery = out.get("battery") or {}
    if isinstance(battery, dict) and battery.get("level") is not None:
        bits.append(f"Body Battery {round(battery['level'])}" +
                    (f" ({battery['band']})" if battery.get("band") else ""))
    stats = out.get("stats") or {}
    if stats.get("hr_avg"):
        bits.append(f"avg HR {round(stats['hr_avg'])}")
    try:
        workouts = store.workouts(out["start"], "9999-12-31T00:00:00Z") or []
        if workouts:
            bits.append(f"{len(workouts)} workout{'s' if len(workouts) != 1 else ''} today")
    except Exception:
        pass
    try:
        streaks = []
        for h in store.habits() or []:
            last = store.latest_relapse(h["id"]) if hasattr(store, "latest_relapse") else None
            # A quit date moved past the last relapse is a fresh start (habits.summary's rule).
            marks = [t for t in (_parse_iso(h.get("started_at"), ctx.zone),
                                 _parse_iso((last or {}).get("at"), ctx.zone)) if t]
            since = max(marks) if marks else None
            if since:
                days = int((ctx.now.timestamp() - since) // 86400)
                streaks.append(f"{h.get('name') or 'habit'} {days} d")
        if streaks:
            bits.append("streaks: " + ", ".join(streaks[:3]))
    except Exception:
        pass
    return "Health today: " + "; ".join(bits) if bits else None


def _email_jobs() -> list:
    try:
        from cron.jobs import list_jobs
        return [j for j in list_jobs(include_disabled=True) if j.get("integration") == "email-monitor"]
    except Exception:
        return []


def _response_lines(text: str) -> List[str]:
    """The job's answer from a cron output file (its "## Response" section),
    without the run's header, prompt or markdown headings."""
    if "## Response" in text:
        text = text.split("## Response", 1)[1]
    return [l.strip() for l in text.splitlines()
            if l.strip() and not l.lstrip().startswith(("#", "**"))]


def inbox_source(ctx) -> Optional[str]:
    lines = []
    cutoff = ctx.now.timestamp() - ctx.lookback_days * 86400
    out_dir = _home() / "cron" / "output"
    for job in _email_jobs():
        folder = out_dir / str(job.get("id"))
        try:
            files = sorted((p for p in folder.glob("*.md") if p.stat().st_mtime >= cutoff),
                           key=lambda p: p.stat().st_mtime, reverse=True)
        except Exception:
            continue
        for path in files[:1]:
            text = _response_lines(path.read_text(encoding="utf-8", errors="ignore"))
            quiet = ("nothing", "no new", "no email", "no activity", "no messages")
            if text and not any(q in text[0].lower() for q in quiet):
                lines.append(f"- {job.get('name') or 'Email'}: " + " ".join(text[:3])[:220])
    fresh = _fresh_inbox_lines()
    lines += [f"- {l}" for l in fresh[:5]]
    return "Inbox\n" + "\n".join(lines[:8]) if lines else None


def messages_source(ctx) -> Optional[str]:
    try:
        from api.imessage_memory import store as im_store
        waiting = im_store().waiting_threads(ctx.now.timestamp() - ctx.lookback_days * 86400)
    except Exception:
        return None
    # His own Jarvis number texting him isn't a person waiting on a reply.
    waiting = [w for w in waiting if "jarvis" not in str(w.get("name") or "").lower()]
    if not waiting:
        return None
    now = ctx.now.timestamp()
    return "Messages waiting on you: " + ", ".join(
        f"{w['name']} ({_ago(w['last_at'], now)})" for w in waiting[:6])


def _car_snapshot() -> Optional[dict]:
    from plugins.toyota.ha import HAClient
    from plugins.toyota.service import car_state

    async def go():
        return await asyncio.wait_for(car_state(HAClient()), CAR_TIMEOUT_S)
    return asyncio.run(go())


def _car_line(car: dict) -> Optional[str]:
    """plugins.toyota.snapshot.build_snapshot's fields, in words."""
    bits = []
    if car.get("fuel_pct") is not None:
        bits.append(f"fuel {round(car['fuel_pct'])}%")
    if car.get("range_mi") is not None:
        bits.append(f"range {round(car['range_mi'])} mi")
    doors = car.get("doors") or {}
    if doors.get("locked") is True:
        bits.append("locked")
    elif doors.get("locked") is False:
        bits.append("UNLOCKED")
    if doors.get("open"):
        bits.append("open: " + ", ".join(doors["open"]))
    if car.get("running"):
        bits.append("running")
    return "car: " + ", ".join(bits) if bits else None


def home_source(ctx) -> Optional[str]:
    bits = []
    try:
        from plugins.door_alarm.service import DoorService
        alarm = DoorService.instance().state().get("alarm") or {}
        if alarm.get("state"):
            bits.append(f"door alarm {alarm['state']}")
    except Exception:
        pass
    try:
        line = _car_line((_car_snapshot() or {}).get("car") or {})
        if line:
            bits.append(line)
    except Exception:
        pass
    try:
        from api.device_bridge import wearables_for
        phone = _phone_id()
        found = wearables_for(phone) if phone else None
        if found:
            rows, _ts = found
            on = [r.get("name") or r.get("model") for r in rows if r.get("connected")]
            if on:
                bits.append("connected: " + ", ".join(on[:4]))
    except Exception:
        pass
    try:
        from api.dashcam_store import store_for_request
        drives = store_for_request().drives() or []
        if drives:
            d = drives[0]
            miles = (d.get("distance_m") or 0) / 1609.34
            start = _parse_iso(d.get("start"), ctx.zone) if isinstance(d.get("start"), str) else d.get("start")
            if start:
                bits.append(f"last drive {miles:.0f} mi, {_ago(float(start), ctx.now.timestamp())}")
    except Exception:
        pass
    return "Home & devices: " + "; ".join(bits) if bits else None


def tasks_source(ctx) -> Optional[str]:
    lines = []
    now = ctx.now.timestamp()
    horizon = now + ctx.horizon_days * 86400
    try:
        from cron.jobs import list_jobs
        for job in list_jobs(include_disabled=False):
            repeat = job.get("repeat") or {}
            when = _parse_iso(job.get("next_run_at"), ctx.zone)
            if repeat.get("times") == 1 and when and now <= when <= horizon:
                d = datetime.fromtimestamp(when, ctx.zone)
                lines.append(f"- reminder {d:%a} {d.day} {d:%b} {d:%I:%M %p}".replace(" 0", " ")
                             + f": {job.get('name') or job.get('prompt', '')[:80]}")
    except Exception:
        pass
    for r in snapshot().get("reminders") or []:
        due = _parse_iso(r.get("due_iso"), ctx.zone)
        when = ""
        if due:
            d = datetime.fromtimestamp(due, ctx.zone)
            when = f" (due {d:%a} {d.day} {d:%b})"
        lines.append(f"- {r.get('title')}{when}")
    try:
        from agent.agent_notes import NotesStore
        for note in NotesStore().list() or []:
            for todo in (note.get("todos") if isinstance(note, dict) else []) or []:
                if not todo.get("done") and todo.get("text"):
                    lines.append(f"- {todo['text']}")
    except Exception:
        pass
    return "Open tasks & reminders\n" + "\n".join(lines[:10]) if lines else None


# ── the fresh inbox check (every 30 min, on the memory model) ────────────
_FRESH_KEY = "fresh_inbox"


def _store():
    from plugins.memory.jarvis_memory import external
    return external._open()[0]


def _fresh_inbox_lines() -> List[str]:
    try:
        raw = _store().kv_get("__brief__", _FRESH_KEY)
        data = json.loads(raw) if raw else {}
    except Exception:
        return []
    if time.time() - float(data.get("at") or 0) > 2 * 86400:
        return []
    return [str(l) for l in data.get("lines") or []]


def _decode_header(raw: bytes) -> str:
    """'Subject: =?UTF-8?B?…?=' → readable text."""
    from email.header import decode_header, make_header
    text = " ".join(raw.decode("utf-8", "ignore").split())
    try:
        return str(make_header(decode_header(text)))
    except Exception:
        return text


def _imap_headers(since: datetime) -> List[str]:
    """Headers (From / Subject / Date) of unread mail since ``since`` — read
    with BODY.PEEK so nothing is marked read. [] without credentials."""
    addr, pwd, host = (os.getenv("EMAIL_ADDRESS"), os.getenv("EMAIL_PASSWORD"),
                       os.getenv("EMAIL_IMAP_HOST"))
    if not (addr and pwd and host):
        return []
    import imaplib
    port = int(os.getenv("EMAIL_IMAP_PORT") or 993)
    out = []
    conn = imaplib.IMAP4_SSL(host, port, timeout=20)
    try:
        conn.login(addr, pwd)
        conn.select("INBOX", readonly=True)
        _typ, data = conn.search(None, "UNSEEN", "SINCE", since.strftime("%d-%b-%Y"))
        ids = (data[0] or b"").split()[-40:]
        for mid in ids:
            _typ, msg = conn.fetch(mid, "(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
            for part in msg or []:
                if isinstance(part, tuple):
                    out.append(_decode_header(part[1])[:240])
    finally:
        try:
            conn.logout()
        except Exception:
            pass
    return out


INBOX_PROMPT = """These are headers of Pranav's unread emails. List only the ones he would want to know about
today (people writing to him, bills due, deliveries, travel, appointments, security alerts) — skip newsletters,
promotions and notifications. One short line each like "From — what it's about". Output ONLY a JSON array of
strings, at most 5; [] when nothing matters.

{headers}
"""


def check_inbox_once() -> Optional[List[str]]:
    """None when there's nothing to check with; else the important lines (cached)."""
    if not (os.getenv("EMAIL_ADDRESS") and os.getenv("EMAIL_PASSWORD") and os.getenv("EMAIL_IMAP_HOST")):
        return None
    from plugins.memory.jarvis_memory import brief, llm
    headers = _imap_headers(datetime.now() - timedelta(days=2))
    import hashlib
    digest = hashlib.sha256("\n".join(sorted(headers)).encode("utf-8")).hexdigest()
    try:
        cached = json.loads(_store().kv_get("__brief__", _FRESH_KEY) or "{}")
    except ValueError:
        cached = {}
    if cached.get("digest") == digest:  # same unread mail as last time: no model call
        cached["at"] = time.time()
        _store().kv_set("__brief__", _FRESH_KEY, json.dumps(cached))
        return list(cached.get("lines") or [])
    if not headers:  # all read: nothing to show
        _store().kv_set("__brief__", _FRESH_KEY, json.dumps({"at": time.time(), "lines": [], "digest": digest}))
        brief.mark_dirty()
        return []
    reply = llm.complete(INBOX_PROMPT.format(headers="\n".join(headers)), 600)
    try:
        import re
        lines = json.loads(re.search(r"\[.*\]", reply, re.DOTALL).group(0))
        lines = [str(l)[:200] for l in lines if str(l).strip()][:5]
    except Exception:
        return None
    _store().kv_set("__brief__", _FRESH_KEY, json.dumps({"at": time.time(), "lines": lines, "digest": digest}))
    brief.mark_dirty()
    return lines


def _inbox_loop():
    while True:
        try:
            check_inbox_once()
        except Exception:
            logger.info("brief: fresh inbox check failed", exc_info=True)
        time.sleep(INBOX_EVERY_S)


_started = threading.Event()


def register_all() -> None:
    from plugins.memory.jarvis_memory import brief
    brief.register_source("location", location_source, order=1)
    brief.register_data("calendar", calendar_items)
    brief.register_source("health", health_source, order=40)
    brief.register_source("inbox", inbox_source, order=50)
    brief.register_source("messages", messages_source, order=55)
    brief.register_source("home", home_source, order=60, timeout_s=CAR_TIMEOUT_S + 0.5)
    brief.register_source("tasks", tasks_source, order=70)
    if not _started.is_set():
        _started.set()
        threading.Thread(target=_inbox_loop, daemon=True, name="brief-inbox").start()
