"""Shared service plumbing: the HTTP wrapper, error hints, backoff and the models."""
from __future__ import annotations

import httpx
import pytest

from jarvis_services.base import (
    Action, Detail, HttpError, Http, Item, Section, Snapshot, Stat,
    backoff_delay, call_json, describe,
)
from jarvis_services.testing import FakeHttp


# ── HTTP wrapper ────────────────────────────────────────────────────────────────

def test_http_wraps_httpx_and_passes_headers():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["auth"] = request.headers.get("Authorization")
        seen["url"] = str(request.url)
        return httpx.Response(200, json={"ok": True})

    http = Http(client=httpx.Client(transport=httpx.MockTransport(handler)))
    r = http.request("GET", "https://api.example.com/v1/x", headers={"Authorization": "Bearer t"},
                     params={"limit": 3})
    assert r.status == 200
    assert r.json() == {"ok": True}
    assert seen == {"auth": "Bearer t", "url": "https://api.example.com/v1/x?limit=3"}


def test_http_network_failure_is_status_zero():
    def handler(request):
        raise httpx.ConnectError("boom", request=request)

    http = Http(client=httpx.Client(transport=httpx.MockTransport(handler)))
    with pytest.raises(HttpError) as e:
        http.request("GET", "https://api.example.com/")
    assert e.value.status == 0


@pytest.mark.parametrize("body,expected", [
    ({"message": "Bad credentials"}, "Bad credentials"),
    ({"error": {"message": "Invalid API Key provided"}}, "Invalid API Key provided"),
    ({"error": "nope"}, "nope"),
])
def test_call_json_raises_with_the_service_message(body, expected):
    http = FakeHttp().add("GET", "https://x.test/a", body, status=401)
    with pytest.raises(HttpError) as e:
        call_json(http, "GET", "https://x.test/a")
    assert e.value.status == 401
    assert e.value.message == expected


def test_call_json_reads_retry_after_on_429():
    http = FakeHttp().add("GET", "https://x.test/a", {"message": "slow down"}, status=429,
                          headers={"Retry-After": "120"})
    with pytest.raises(HttpError) as e:
        call_json(http, "GET", "https://x.test/a")
    assert e.value.retry_after == 120


def test_call_json_empty_body_is_empty_dict():
    http = FakeHttp().add("PATCH", "https://x.test/a", b"", status=204)
    assert call_json(http, "PATCH", "https://x.test/a") == {}


# ── error hints ─────────────────────────────────────────────────────────────────

def test_describe_401_403_404_429_5xx_and_offline():
    assert "refused (401)" in describe(HttpError(401, "Unauthorized"), "Vercel")
    assert describe(HttpError(403, "scope missing"), "GitHub").startswith("Not allowed with this key (403)")
    assert describe(HttpError(404, ""), "n8n") == "Not found (404)."
    assert "Rate limited (429)" in describe(HttpError(429, ""), "Notion")
    assert "Cal.com is having trouble (503)" in describe(HttpError(503, ""), "Cal.com")
    assert describe(HttpError(0, "timed out"), "Resend") == "Can't reach Resend: timed out"


def test_describe_uses_service_hints_first():
    hint = "That's a publishable key. Use the secret key (sk_live_… not pk_live_…)."
    assert describe(HttpError(403, "x"), "Stripe", hints={403: hint}) == hint


def test_describe_resend_restricted_key():
    msg = describe(HttpError(401, "This API key is restricted to only send emails"), "Resend")
    assert "only send emails" in msg and "Full access" in msg


# ── backoff ─────────────────────────────────────────────────────────────────────

def test_backoff_doubles_and_caps():
    assert backoff_delay(30, 1) == 60
    assert backoff_delay(30, 2) == 120
    assert backoff_delay(30, 20) == 900
    assert backoff_delay(1800, 3) == 1800       # never below the normal interval
    assert backoff_delay(15, 1, retry_after=300) == 300


# ── models ──────────────────────────────────────────────────────────────────────

def _snap(**kw):
    base = dict(id="vercel", display_name="Vercel", tone="ok", headline="app · Ready",
                reason="Last deploy is live", sections=[Section("Deployments", [Item("app", "Ready")])],
                updated_at=1.0)
    base.update(kw)
    return Snapshot(**base)


def test_snapshot_shape():
    d = _snap().to_dict()
    assert set(d) == {"id", "display_name", "tone", "headline", "reason", "sections",
                      "updated_at", "error", "extra"}
    item = d["sections"][0]["items"][0]
    assert set(item) == {"title", "subtitle", "value", "url", "tone", "date", "badge", "actions"}


def test_snapshot_same_content_ignores_updated_at_and_state():
    a = _snap(updated_at=1.0, state={"x": 1})
    b = _snap(updated_at=99.0, state={"x": 2})
    assert a.same_content(b)
    assert not a.same_content(_snap(reason="Last deploy failed"))


def test_detail_offered_finds_only_offered_actions():
    redeploy = Action("vercel.redeploy", "Redeploy", "d1|app|")
    d = Detail("vercel", "Vercel", stats=[Stat("Ready", "1")],
               sections=[Section("Deployments", [Item("app", actions=[redeploy])])], fetched_at=5.0)
    assert d.offered("vercel.redeploy", "d1|app|") == redeploy
    assert d.offered("vercel.redeploy", "d2|app|") is None
    assert d.offered("vercel.cancel", "d1|app|") is None
    out = d.to_dict()
    assert out["sections"][0]["items"][0]["actions"][0] == {
        "kind": "vercel.redeploy", "title": "Redeploy", "target": "d1|app|", "symbol": "",
        "destructive": False, "confirm": None}
    assert set(out) == {"id", "display_name", "stats", "sections", "fetched_at", "error", "last_action"}


def test_fake_http_records_calls_and_matches_query():
    http = FakeHttp().add("GET", "https://x.test/a?limit=5", {"n": 1})
    r = http.request("GET", "https://x.test/a", params={"limit": 5}, headers={"A": "1"})
    assert r.json() == {"n": 1}
    assert http.calls[0].headers == {"A": "1"}
    assert http.request("GET", "https://x.test/zzz").status == 404
