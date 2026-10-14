"""Stripe: balance + recent charges every 30 s, read-only detail, payment events."""
from __future__ import annotations

import base64

from jarvis_services.base import HttpError
from jarvis_services.config import ConfigView
from jarvis_services.stripe import StripeService, money
from jarvis_services.testing import FakeHttp

NOW = 1_791_936_000.0  # 2026-10-14 00:00 UTC
KEY = "sk_test_51abc"
CFG = ConfigView({"SERVICES_STRIPE_API_KEY": KEY}, {}, environ={})

BALANCE = {
    "object": "balance",
    "available": [{"amount": 124000, "currency": "eur", "source_types": {"card": 124000}}],
    "pending": [{"amount": 5000, "currency": "eur", "source_types": {"card": 5000}}],
    "livemode": False,
}


def charge(cid, amount=2500, status="succeeded", created=NOW - 600, **extra):
    c = {"id": cid, "object": "charge", "amount": amount, "currency": "eur", "status": status,
         "created": created, "description": "Pro plan", "billing_details": {"name": "Ada"},
         "refunded": False, "amount_refunded": 0, "captured": True}
    c.update(extra)
    return c


def http_with(charges):
    return (FakeHttp()
            .add("GET", "https://api.stripe.com/v1/balance", BALANCE)
            .add("GET", "https://api.stripe.com/v1/charges?limit=3",
                 {"object": "list", "data": charges, "has_more": False}))


def test_interval_and_configured():
    s = StripeService()
    assert s.interval == 30
    assert s.configured(CFG)
    assert not s.configured(ConfigView({}, {}, environ={}))


def test_fetch_uses_basic_auth_and_builds_the_snapshot():
    http = http_with([charge("ch_2"), charge("ch_1", amount=900)])
    snap = StripeService().fetch(http, CFG, None, NOW)
    expected = "Basic " + base64.b64encode(f"{KEY}:".encode()).decode()
    assert {c.headers["Authorization"] for c in http.calls} == {expected}
    assert snap.id == "stripe" and snap.tone == "ok"
    assert snap.headline == "Balance 1,290.00 EUR"
    assert snap.reason == "Last payment received: 25.00 EUR · Pro plan"
    items = snap.sections[0].items
    assert [i.title for i in items] == ["25.00 EUR", "9.00 EUR"]
    assert items[0].subtitle == "Pro plan · succeeded" and items[0].tone == "ok"
    assert items[0].date == NOW - 600


def test_tone_follows_the_latest_charge():
    old = StripeService().fetch(http_with([charge("c", created=NOW - 2 * 86400)]), CFG, None, NOW)
    assert old.tone == "idle"
    failed = StripeService().fetch(http_with([charge("c", status="failed")]), CFG, None, NOW)
    assert failed.tone == "error" and failed.reason.startswith("Last payment failed")
    pending = StripeService().fetch(http_with([charge("c", status="pending")]), CFG, None, NOW)
    assert pending.tone == "warning"
    none = StripeService().fetch(http_with([]), CFG, None, NOW)
    assert none.tone == "idle" and none.reason == "No payment yet" and none.sections == []


def test_publishable_key_hint_on_403():
    s = StripeService()
    msg = s.describe(HttpError(403, "The provided key 'pk_live_…' does not have the required permissions"))
    assert "secret key" in msg and "pk_live_" in msg


def test_payment_received_event_rules():
    s = StripeService()
    first = s.fetch(http_with([charge("ch_1")]), CFG, None, NOW)
    assert s.events(None, first.state) == []                       # first poll is silent
    same = s.fetch(http_with([charge("ch_1")]), CFG, first, NOW)
    assert s.events(first.state, same.state) == []
    new = s.fetch(http_with([charge("ch_2", amount=4200), charge("ch_1")]), CFG, same, NOW)
    events = s.events(same.state, new.state)
    assert [(e.kind, e.title, e.body) for e in events] == [
        ("payment_received", "Payment received", "42.00 EUR · Pro plan")]
    failed = s.fetch(http_with([charge("ch_3", status="failed"), charge("ch_2")]), CFG, new, NOW)
    assert s.events(new.state, failed.state) == []


def test_charges_failure_keeps_the_previous_list():
    s = StripeService()
    first = s.fetch(http_with([charge("ch_1")]), CFG, None, NOW)
    http = FakeHttp().add("GET", "https://api.stripe.com/v1/balance", BALANCE)
    http.add("GET", "https://api.stripe.com/v1/charges?limit=3", {"error": {"message": "x"}}, status=500)
    again = s.fetch(http, CFG, first, NOW)
    assert [i.title for i in again.sections[0].items] == ["25.00 EUR"]


def test_money_handles_zero_decimal_currencies():
    assert money(150000, "jpy") == "150,000 JPY"
    assert money(1999, "usd") == "19.99 USD"


def test_detail_is_read_only_with_mrr():
    sub = {"id": "sub_1", "currency": "eur", "items": {"data": [
        {"quantity": 2, "price": {"unit_amount": 1000, "currency": "eur",
                                  "recurring": {"interval": "month", "interval_count": 1}}},
        {"quantity": 1, "price": {"unit_amount": 12000, "currency": "eur",
                                  "recurring": {"interval": "year", "interval_count": 1}}},
        {"quantity": 1, "price": {"unit_amount": 5, "currency": "eur",
                                  "recurring": {"interval": "month", "usage_type": "metered"}}},
    ]}}
    http = (FakeHttp()
            .add("GET", "https://api.stripe.com/v1/balance", BALANCE)
            .add("GET", "https://api.stripe.com/v1/charges?limit=15",
                 {"data": [charge("ch_1", refunded=True), charge("ch_2", captured=False)]})
            .add("GET", "https://api.stripe.com/v1/payouts?limit=5",
                 {"data": [{"amount": 50000, "currency": "eur", "status": "in_transit",
                            "arrival_date": NOW + 86400}]})
            .add("GET", "https://api.stripe.com/v1/subscriptions?status=active&limit=100",
                 {"data": [sub], "has_more": False}))
    d = StripeService().detail(http, CFG, NOW)
    assert {c.headers["Authorization"] for c in http.calls} == {f"Bearer {KEY}"}
    stats = {s.label: s.value for s in d.stats}
    assert stats == {"Available": "1,240.00 EUR", "Pending": "50.00 EUR",
                     "Subscriptions": "1", "Est. MRR": "30.00 EUR"}
    payments = d.sections[0]
    assert [i.badge for i in payments.items] == ["Refunded", "Uncaptured"]
    assert d.sections[1].title == "Payouts" and d.sections[1].items[0].badge == "In Transit"
    assert all(not i.actions for s in d.sections for i in s.items)
    assert StripeService().actions == frozenset()
