"""Cal.com: upcoming bookings every 300 s, "booking soon" event, read-only detail."""
from __future__ import annotations

from datetime import datetime, timezone

from jarvis_services.calcom import CalcomService
from jarvis_services.config import ConfigView
from jarvis_services.testing import FakeHttp

NOW = 1_791_936_000.0  # 2026-10-14 00:00 UTC
KEY = "cal_live_123"
CFG = ConfigView({"SERVICES_CALCOM_API_KEY": KEY}, {}, environ={})
BOOKINGS = "https://api.cal.com/v2/bookings"


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat().replace("+00:00", ".000Z")


def booking(bid, start_in, status="accepted", minutes=30, title="Intro call"):
    start = NOW + start_in
    return {"id": bid, "title": title, "status": status, "start": iso(start), "end": iso(start + minutes * 60),
            "attendees": [{"name": "Ada", "email": "ada@example.com"}]}


def http_with(bookings):
    return FakeHttp().add("GET", BOOKINGS, {"status": "success", "data": bookings})


def test_poll_request():
    s = CalcomService()
    assert s.interval == 300
    http = http_with([])
    s.fetch(http, CFG, None, NOW)
    call = http.calls[0]
    assert call.headers == {"Authorization": f"Bearer {KEY}", "cal-api-version": "2024-08-13"}
    assert call.params["status"] == "upcoming" and call.params["take"] == "50"
    assert set(call.params) == {"status", "afterStart", "beforeEnd", "take"}


def test_snapshot_next_and_soon():
    later = CalcomService().fetch(http_with([booking(1, 3 * 3600)]), CFG, None, NOW)
    assert later.tone == "info" and later.reason == "Next: Intro call with Ada, in 3 h"
    assert later.headline == "1 upcoming booking"
    soon = CalcomService().fetch(http_with([booking(1, 25 * 60), booking(2, 86400)]), CFG, None, NOW)
    assert soon.tone == "warning" and soon.reason == "Starting soon: Intro call with Ada, in 25 min"
    none = CalcomService().fetch(http_with([booking(3, 3600, status="cancelled")]), CFG, None, NOW)
    assert none.tone == "idle" and none.reason == "No upcoming booking"
    ended = CalcomService().fetch(http_with([booking(4, -7200)]), CFG, None, NOW)
    assert ended.sections == []


def test_booking_soon_event_fires_once():
    s = CalcomService()
    first = s.fetch(http_with([booking(1, 2 * 3600)]), CFG, None, NOW)
    assert s.events(None, first.state) == []
    soon = s.fetch(http_with([booking(1, 50 * 60)]), CFG, first, NOW)
    events = s.events(first.state, soon.state)
    assert [(e.kind, e.title, e.body) for e in events] == [("booking_soon", "Booking soon",
                                                             "Intro call with Ada, in 50 min")]
    again = s.fetch(http_with([booking(1, 45 * 60)]), CFG, soon, NOW)
    assert s.events(soon.state, again.state) == []


def test_detail_counts_today_and_week():
    http = http_with([booking(1, 600), booking(2, 3 * 86400), booking(3, 10 * 86400)])
    d = CalcomService().detail(http, CFG, NOW)
    assert http.calls[0].params["take"] == "30"
    stats = {s.label: s.value for s in d.stats}
    assert stats["Next 7 days"] == "2" and stats["Upcoming"] == "3"
    assert all(not i.actions for s in d.sections for i in s.items)
