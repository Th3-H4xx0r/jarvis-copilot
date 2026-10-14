"""The hub: one thread, configured services only, one publish per change, events →
notifications, errors kept and backed off, details cached, actions checked."""
from __future__ import annotations

import threading
import time

import pytest

from jarvis_services.base import (
    Action, Detail, Event, HttpError, Item, Section, Service, ServiceError, Snapshot,
)
from jarvis_services.config import ConfigView
from jarvis_services.loop import ServicesHub


class Clock:
    def __init__(self, t=1_791_936_000.0):
        self.t = t

    def __call__(self):
        return self.t


class FakeConfig:
    def __init__(self, env=None, settings=None):
        self.env = dict(env or {})
        self.settings = dict(settings or {})
        self.loads = 0

    def load(self):
        self.loads += 1
        return ConfigView(self.env, self.settings, environ={})


class Counter(Service):
    """Snapshot headline = whatever ``value`` holds; events when it changes."""
    topic = "services"
    interval = 30
    first_delay = 5

    def __init__(self, sid="alpha", env="ALPHA_KEY", kind=None):
        self.id = sid
        self.display_name = sid.title()
        self.secrets = {"key": env}
        self.value = "one"
        self.fail = None
        self.fetches = 0
        self.kind = kind or f"{sid}.poke"
        self.actions = frozenset({self.kind})
        self.performed = []

    def fetch(self, http, cfg, prev=None, now=None):
        self.fetches += 1
        if self.fail:
            raise self.fail
        return Snapshot(self.id, self.display_name, "ok", self.value, "why", [], now, state=self.value)

    def events(self, old, new):
        if old is None or old == new:
            return []
        return [Event("changed", f"{self.display_name} changed", f"{old} → {new}", {"to": new})]

    def detail(self, http, cfg, now=None):
        return Detail(self.id, self.display_name, sections=[Section("Things", [
            Item("thing", actions=[Action(self.kind, "Poke", "t1")])])], fetched_at=now)

    def perform(self, http, cfg, kind, target):
        self.performed.append((kind, target))
        return "Poked"


def make(services, env=None, **kw):
    published, notified = [], []
    clock = Clock()
    hub = ServicesHub(services, FakeConfig(env, kw.pop("settings", None)), http=object(),
                      publish=lambda topic, data: published.append((topic, data)),
                      notify=lambda title, body, data: notified.append((title, body, data)),
                      clock=clock, sleep=lambda s: None, **kw)
    hub.tick()          # boot: configured services are first polled `first_delay` after this
    return hub, clock, published, notified


def test_nothing_configured_means_no_work():
    svc = Counter()
    hub, clock, published, notified = make([svc])
    assert hub.tick() is None
    clock.t += 3600
    assert hub.tick() is None
    assert svc.fetches == 0 and published == [] and notified == []
    assert hub.snapshots() == []


def test_polls_after_first_delay_and_publishes_once_per_change():
    a, b = Counter("alpha", "A"), Counter("beta", "B")
    hub, clock, published, _ = make([a, b], env={"A": "x", "B": "y"})
    assert hub.tick() == pytest.approx(5)          # both due in 5 s
    assert a.fetches == 0
    clock.t += 5
    hub.tick()
    assert a.fetches == b.fetches == 1
    assert len(published) == 1                      # two new snapshots, one publish
    topic, data = published[0]
    assert topic == "services" and [s["id"] for s in data["services"]] == ["alpha", "beta"]
    assert data["ts"] == clock.t
    clock.t += 30
    hub.tick()                                      # same content: nothing published
    assert a.fetches == 2 and len(published) == 1
    a.value = "two"
    clock.t += 30
    hub.tick()
    assert len(published) == 2 and published[1][1]["services"][0]["headline"] == "two"


def test_events_become_notifications_first_poll_silent():
    a = Counter()
    hub, clock, _, notified = make([a], env={"ALPHA_KEY": "x"})
    clock.t += 5
    hub.tick()
    assert notified == []
    a.value = "two"
    clock.t += 30
    hub.tick()
    assert notified == [("Alpha changed", "one → two", {"service": "alpha", "kind": "changed", "to": "two"})]


def test_notify_and_publish_failures_never_break_the_hub():
    a = Counter()
    clock = Clock()

    def boom(*args):
        raise RuntimeError("down")

    hub = ServicesHub([a], FakeConfig({"ALPHA_KEY": "x"}), http=object(), publish=boom, notify=boom,
                      clock=clock, sleep=lambda s: None)
    hub.tick()
    clock.t += 5
    hub.tick()
    a.value = "two"
    clock.t += 30
    hub.tick()
    assert a.fetches == 2


def test_error_without_previous_snapshot_then_backoff():
    a = Counter()
    a.fail = HttpError(401, "Bad credentials")
    hub, clock, published, _ = make([a], env={"ALPHA_KEY": "x"})
    clock.t += 5
    delay = hub.tick()
    snap = hub.snapshots()[0]
    assert snap["tone"] == "error" and snap["headline"] == "Can't reach Alpha"
    assert "refused (401)" in snap["error"]
    assert delay == pytest.approx(60)               # 30 s interval, doubled
    clock.t += 60
    assert hub.tick() == pytest.approx(120)
    assert len(published) == 1                      # same error: one publish


def test_error_after_success_keeps_the_last_good_content():
    a = Counter()
    hub, clock, published, _ = make([a], env={"ALPHA_KEY": "x"})
    clock.t += 5
    hub.tick()
    a.fail = HttpError(503, "")
    clock.t += 30
    hub.tick()
    snap = hub.snapshots()[0]
    assert snap["headline"] == "one" and "having trouble (503)" in snap["error"]
    a.fail = None
    clock.t += 60
    hub.tick()
    assert hub.snapshots()[0]["error"] is None
    assert len(published) == 3


def test_rate_limit_retry_after_is_respected():
    a = Counter()
    a.fail = HttpError(429, "slow", retry_after=1200)
    hub, clock, _, _ = make([a], env={"ALPHA_KEY": "x"})
    clock.t += 5
    assert hub.tick() == pytest.approx(1200)


def test_a_bug_in_a_service_is_contained():
    a = Counter()
    a.fail = ZeroDivisionError("oops")
    hub, clock, _, _ = make([a], env={"ALPHA_KEY": "x"})
    clock.t += 5
    hub.tick()
    assert hub.snapshots()[0]["tone"] == "error"


def test_unconfigured_service_is_dropped_and_published():
    a = Counter()
    hub, clock, published, _ = make([a], env={"ALPHA_KEY": "x"})
    clock.t += 5
    hub.tick()
    hub.config.env.clear()
    clock.t += 1
    assert hub.tick() is None
    assert hub.snapshots() == [] and published[-1][1]["services"] == []


def test_next_interval_is_used():
    a = Counter()
    a.next_interval = lambda snapshot: 60 if snapshot.headline == "busy" else 300
    a.value = "busy"
    hub, clock, _, _ = make([a], env={"ALPHA_KEY": "x"})
    clock.t += 5
    assert hub.tick() == pytest.approx(60)


def test_wake_polls_a_service_now():
    a = Counter()
    hub, clock, _, _ = make([a], env={"ALPHA_KEY": "x"})
    hub.tick()
    hub.wake("alpha")
    hub.tick()
    assert a.fetches == 1


def test_portfolio_topic_payload():
    class Board(Counter):
        topic = "portfolio"

    crypto = Board("crypto", "C")
    hub, clock, published, _ = make([Counter(), crypto], env={"C": "x"})
    clock.t += 5
    hub.tick()
    assert [t for t, _ in published] == ["portfolio"]
    data = published[0][1]
    assert data["crypto"]["headline"] == "one" and data["portfolio"] is None and "ts" in data
    assert hub.portfolio()["crypto"]["headline"] == "one"


def test_detail_is_cached_for_60_seconds():
    a = Counter()
    calls = []
    real = a.detail
    a.detail = lambda http, cfg, now=None: calls.append(now) or real(http, cfg, now)
    hub, clock, _, _ = make([a], env={"ALPHA_KEY": "x"})
    first = hub.detail("alpha")
    clock.t += 59
    assert hub.detail("alpha") == first and len(calls) == 1
    clock.t += 2
    hub.detail("alpha")
    assert len(calls) == 2
    with pytest.raises(KeyError):
        hub.detail("nope")


def test_detail_without_key_and_on_error():
    a = Counter()
    hub, clock, _, _ = make([a])
    assert "No Alpha key" in hub.detail("alpha")["error"]
    hub.config.env["ALPHA_KEY"] = "x"
    a.detail = lambda http, cfg, now=None: (_ for _ in ()).throw(ServiceError("down for maintenance"))
    assert hub.detail("alpha")["error"] == "down for maintenance"


def test_action_runs_only_what_was_offered():
    n8n = Counter("n8n", "N8N_KEY", kind="n8n.retry")
    hub, clock, _, _ = make([n8n], env={"N8N_KEY": "x"})
    refused = hub.action("n8n", "n8n.retry", "t1")                 # no detail seen yet
    assert refused["ok"] is False and refused["result"] is None and n8n.performed == []
    assert refused["detail"]["last_action"]["ok"] is False
    done = hub.action("n8n", "n8n.retry", "t1")                    # offered by the refreshed detail
    assert done["ok"] is True and done["result"]["message"] == "Poked"
    assert done["detail"]["last_action"]["title"] == "Poke"
    assert n8n.performed == [("n8n.retry", "t1")]
    again = hub.action("n8n", "n8n.retry", "t1")                   # a double tap
    assert again["ok"] is False and again["error"] == "Already done a moment ago."
    clock.t += 11
    assert hub.action("n8n", "n8n.retry", "t1")["ok"] is True
    assert hub.action("n8n", "n8n.retry", "nope")["ok"] is False
    assert hub.action("n8n", "n8n.activate", "t1")["ok"] is False  # allowlisted, but not offered
    assert len(n8n.performed) == 2


def test_unlisted_kinds_never_run_even_if_a_service_offers_them():
    rogue = Counter("stripe", "S", kind="stripe.refund")
    hub, clock, _, _ = make([rogue], env={"S": "x"})
    hub.detail("stripe")
    out = hub.action("stripe", "stripe.refund", "t1")
    assert out["ok"] is False and out["error"] == "This action isn't available." and rogue.performed == []


def test_action_stale_offer_is_refused():
    n8n = Counter("n8n", "N8N_KEY", kind="n8n.retry")
    hub, clock, _, _ = make([n8n], env={"N8N_KEY": "x"})
    hub.detail("n8n")
    clock.t += 301
    assert hub.action("n8n", "n8n.retry", "t1")["ok"] is False
    assert n8n.performed == []


def test_thread_start_wake_stop():
    a = Counter()
    a.first_delay = 0
    hub = ServicesHub([a], FakeConfig({"ALPHA_KEY": "x"}), http=object(), publish=lambda *x: None,
                      notify=lambda *x: None)
    hub.start()
    deadline = time.time() + 5
    while a.fetches == 0 and time.time() < deadline:
        time.sleep(0.02)
    assert a.fetches >= 1
    assert sum(1 for t in threading.enumerate() if t.name == "services-hub") == 1
    hub.start()                                                    # idempotent
    assert sum(1 for t in threading.enumerate() if t.name == "services-hub") == 1
    hub.stop()
    assert not any(t.name == "services-hub" and t.is_alive() for t in threading.enumerate())
