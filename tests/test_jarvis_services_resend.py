"""Resend: latest emails every 60 s; read-only detail (no sending, ever)."""
from __future__ import annotations

from jarvis_services.config import ConfigView
from jarvis_services.resend import ResendService
from jarvis_services.testing import FakeHttp

NOW = 1_791_936_000.0  # 2026-10-14 00:00 UTC
KEY = "re_test_123"
CFG = ConfigView({"SERVICES_RESEND_API_KEY": KEY}, {"resend": {"from": "me@example.com"}}, environ={})


def email(eid, event="delivered", subject="Welcome"):
    return {"id": eid, "to": ["ada@example.com"], "from": "me@example.com", "subject": subject,
            "created_at": "2026-10-13 10:00:00.123456+00", "last_event": event}


def test_poll_and_snapshot():
    s = ResendService()
    assert s.interval == 60
    http = FakeHttp().add("GET", "https://api.resend.com/emails?limit=100",
                          {"object": "list", "data": [email(f"e{i}") for i in range(7)]})
    snap = s.fetch(http, CFG, None, NOW)
    assert http.calls[0].headers == {"Authorization": f"Bearer {KEY}", "Accept": "application/json"}
    assert snap.tone == "ok"
    assert snap.headline == "7 emails sent"
    assert snap.reason == "Last email delivered: Welcome"
    items = snap.sections[0].items
    assert len(items) == 5
    assert items[0].subtitle == "to ada@example.com · delivered"
    assert items[0].date == 1_791_885_600.123456


def test_tones():
    def tone(event):
        http = FakeHttp().add("GET", "https://api.resend.com/emails?limit=100", {"data": [email("e", event)]})
        return ResendService().fetch(http, CFG, None, NOW)
    assert tone("bounced").tone == "error"
    delayed = tone("delivery_delayed")
    assert delayed.tone == "warning" and delayed.reason == "Last email is delayed: Welcome"
    assert tone("sent").tone == "info"


def test_detail_has_domains_and_no_actions():
    http = (FakeHttp()
            .add("GET", "https://api.resend.com/emails?limit=20", {"data": [email("e1"), email("e2", "bounced")]})
            .add("GET", "https://api.resend.com/domains", {"data": [
                {"name": "example.com", "status": "verified", "region": "us-east-1"}]}))
    d = ResendService().detail(http, CFG, NOW)
    assert {s.label: s.value for s in d.stats} == {"Delivered": "1", "Bounced": "1", "Domains": "1"}
    assert [s.title for s in d.sections] == ["Latest emails", "Domains"]
    assert ResendService().actions == frozenset()
    assert all(c.method == "GET" for c in http.calls)
