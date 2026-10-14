"""Cal.com: upcoming bookings (next 60 days) every 5 minutes, and a "booking soon"
notification once per booking when it is under an hour away. Read only: cancelling
emails the guest and can refund or charge them.

Times in text are relative ("in 25 min"); items carry ``date`` for the phone and the
Mac to show in their own time zone.

after coucou (github.com/Louis-CFM/coucou, MIT)
"""
from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone

from jarvis_services.base import (
    IDLE, INFO, WARNING, Detail, Event, Item, Section, Service, Snapshot, Stat, call_json, parse_date,
    plural,
)

BOOKINGS = "https://api.cal.com/v2/bookings"
ENV = "SERVICES_CALCOM_API_KEY"
SOON = 3600


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def relative(seconds: float) -> str:
    if seconds < 60:
        return "now"
    if seconds < 3600:
        return f"in {int(seconds // 60)} min"
    if seconds < 86400:
        return f"in {int(seconds // 3600)} h"
    days = int(seconds // 86400)
    return f"in {days} day{'' if days == 1 else 's'}"


def _parse(b: dict):
    if not isinstance(b, dict):
        return None
    bid = b.get("id")
    if isinstance(bid, str) and bid.isdigit():
        bid = int(bid)
    if not isinstance(bid, int) or isinstance(bid, bool):
        return None
    start = parse_date(b.get("start") or b.get("startTime"))
    if start is None:
        return None
    attendees = b.get("attendees") if isinstance(b.get("attendees"), list) else []
    first = attendees[0] if attendees and isinstance(attendees[0], dict) else {}
    status = str(b.get("status") or "accepted")
    return {"id": bid, "title": b.get("title") or "Meeting", "status": status,
            "start": start, "end": parse_date(b.get("end") or b.get("endTime")) or start,
            "attendee": first.get("name"), "email": first.get("email"),
            "active": status.upper() in ("ACCEPTED", "PENDING")}


def _with(b: dict) -> str:
    return f" with {b['attendee']}" if b["attendee"] else ""


class CalcomService(Service):
    id = "calcom"
    display_name = "Cal.com"
    interval = 300
    first_delay = 8
    secrets = {"api_key": ENV}
    secret_labels = {"api_key": "API key"}

    @staticmethod
    def _headers(cfg) -> dict:
        return {"Authorization": f"Bearer {cfg.secret(ENV)}", "cal-api-version": "2024-08-13"}

    def fetch(self, http, cfg, prev=None, now=None) -> Snapshot:
        now = now or time.time()
        today = datetime.fromtimestamp(now).astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
        # API v2 filters on afterStart / beforeEnd (`start` / `end` aren't parameters there).
        body = call_json(http, "GET", BOOKINGS, headers=self._headers(cfg), timeout=10, params={
            "status": "upcoming", "afterStart": _iso(today.timestamp()),
            "beforeEnd": _iso((today + timedelta(days=60)).timestamp()), "take": "50"})
        bookings = [b for b in map(_parse, body.get("data") or []) if b]
        upcoming = sorted((b for b in bookings if b["end"] > now), key=lambda b: b["start"])
        nxt = next((b for b in upcoming if b["active"]), None)
        if nxt:
            soon = nxt["start"] - now < SOON
            tone = WARNING if soon else INFO
            reason = (f"{'Starting soon' if soon else 'Next'}: {nxt['title']}{_with(nxt)}, "
                      f"{relative(nxt['start'] - now)}")
        else:
            tone, reason = IDLE, "No upcoming booking"
        items = [Item(b["title"], " · ".join(x for x in (b["attendee"], b["status"].lower()) if x),
                      tone=INFO if b["active"] else IDLE, date=b["start"]) for b in upcoming[:10]]
        state = {"soon": {b["id"]: b for b in upcoming if b["active"] and 0 < b["start"] - now <= SOON},
                 "now": now}
        return Snapshot(self.id, self.display_name, tone,
                        plural(sum(1 for b in upcoming if b["active"]), "upcoming booking"), reason,
                        [Section("Upcoming", items)] if items else [], now, state=state)

    def events(self, old_state, new_state) -> list:
        if not old_state or not new_state:
            return []
        out = []
        for bid, b in new_state["soon"].items():
            if bid not in old_state["soon"]:
                out.append(Event("booking_soon", "Booking soon",
                                 f"{b['title']}{_with(b)}, {relative(b['start'] - new_state['now'])}",
                                 {"booking": bid, "start": b["start"]}))
        return out

    def detail(self, http, cfg, now=None) -> Detail:
        now = now or time.time()
        body = call_json(http, "GET", BOOKINGS, headers=self._headers(cfg),
                         params={"status": "upcoming", "afterStart": _iso(now), "take": "30"})
        today = datetime.fromtimestamp(now).date()
        items, n_today, n_week = [], 0, 0
        for raw in body.get("data") or []:
            b = _parse(raw)
            if not b:
                continue
            is_today = datetime.fromtimestamp(b["start"]).date() == today
            n_today += is_today
            n_week += b["start"] - now < 7 * 86400
            location = raw.get("location") if isinstance(raw.get("location"), str) else ""
            items.append(Item(b["title"], b["attendee"] or b["email"] or "", tone=WARNING if is_today else INFO,
                              date=b["start"],
                              url=raw.get("meetingUrl") or (location if location.startswith("https://") else None),
                              badge=b["status"].capitalize()))
        return Detail(self.id, self.display_name,
                      [Stat("Today", str(n_today), WARNING if n_today else IDLE),
                       Stat("Next 7 days", str(n_week), INFO), Stat("Upcoming", str(len(items)))],
                      [Section("Upcoming bookings", items, None if items else "Nothing booked.")], now)
