"""Vercel: terminal deployments every 30 s, project filter, deploy events, detail actions."""
from __future__ import annotations

import pytest

from jarvis_services.base import ServiceError
from jarvis_services.config import ConfigView
from jarvis_services.testing import FakeHttp
from jarvis_services.vercel import VercelService

NOW = 1_791_936_000.0  # 2026-10-14 00:00 UTC
TOKEN = "vc_test_token"


def cfg(projects=()):
    return ConfigView({"SERVICES_VERCEL_TOKEN": TOKEN}, {"vercel": {"projects": list(projects)}}, environ={})


def dep(uid, name="site", state="READY", branch="main", created_ms=NOW * 1000 - 60_000, target=None):
    return {"uid": uid, "name": name, "url": f"{name}-{uid}.vercel.app", "state": state,
            "createdAt": created_ms, "target": target,
            "meta": {"githubCommitMessage": "Ship it\nmore", "githubCommitRef": branch},
            "creator": {"username": "pranav"}}


def http_with(deps):
    return FakeHttp().add("GET", "https://api.vercel.com/v6/deployments?limit=5", {"deployments": deps})


def test_poll_auth_interval_and_snapshot():
    s = VercelService()
    assert s.interval == 30
    http = http_with([dep("d3", state="BUILDING"), dep("d2"), dep("d1", state="ERROR")])
    snap = s.fetch(http, cfg(), None, NOW)
    assert http.calls[0].headers == {"Authorization": f"Bearer {TOKEN}", "Accept": "application/json"}
    assert snap.tone == "ok"                                         # BUILDING is not terminal
    assert snap.headline == "site · Ready"
    assert snap.reason == "Last deploy is live: site · main"
    items = snap.sections[0].items
    assert [i.subtitle for i in items] == ["Ready · main · Ship it\nmore", "Error · main · Ship it\nmore"]
    assert items[0].url == "https://site-d2.vercel.app"
    assert items[0].date == pytest.approx(NOW - 60)


def test_failed_and_canceled_tones():
    assert VercelService().fetch(http_with([dep("d", state="ERROR")]), cfg(), None, NOW).tone == "error"
    canceled = VercelService().fetch(http_with([dep("d", state="CANCELED")]), cfg(), None, NOW)
    assert canceled.tone == "warning" and canceled.reason.startswith("Last deploy was canceled")


def test_project_filter():
    http = http_with([dep("d2", name="docs", state="ERROR"), dep("d1", name="site")])
    snap = VercelService().fetch(http, cfg(projects=["site"]), None, NOW)
    assert snap.headline == "site · Ready" and len(snap.sections[0].items) == 1


def test_no_deployment_is_idle():
    snap = VercelService().fetch(http_with([]), cfg(), None, NOW)
    assert snap.tone == "idle" and snap.sections == []


def test_deploy_events():
    s = VercelService()
    first = s.fetch(http_with([dep("d1")]), cfg(), None, NOW)
    assert s.events(None, first.state) == []
    same = s.fetch(http_with([dep("d1")]), cfg(), first, NOW)
    assert s.events(first.state, same.state) == []
    failed = s.fetch(http_with([dep("d2", state="ERROR"), dep("d1")]), cfg(), same, NOW)
    assert [(e.kind, e.title, e.body) for e in s.events(same.state, failed.state)] == [
        ("deploy_failed", "Deploy failed", "site · main")]
    ready = s.fetch(http_with([dep("d3"), dep("d2", state="ERROR")]), cfg(), failed, NOW)
    assert [e.kind for e in s.events(failed.state, ready.state)] == ["deploy_ready"]
    canceled = s.fetch(http_with([dep("d4", state="CANCELED")]), cfg(), ready, NOW)
    assert s.events(ready.state, canceled.state) == []


def test_detail_actions():
    http = (FakeHttp()
            .add("GET", "https://api.vercel.com/v6/deployments?limit=20", {"deployments": [
                dep("p1", target="production"), dep("v1"), dep("b1", state="BUILDING"),
                dep("e1", state="ERROR"), dep("c1", state="CANCELED")]})
            .add("GET", "https://api.vercel.com/v9/projects?limit=20",
                 {"projects": [{"name": "site", "framework": "nextjs", "updatedAt": NOW * 1000}]}))
    d = VercelService().detail(http, cfg(), NOW)
    assert d.offered("vercel.redeploy", "p1|site|production") is not None
    assert d.offered("vercel.promote", "p1|site") is None             # already production
    promote = d.offered("vercel.promote", "v1|site")
    assert promote is not None and promote.confirm
    cancel = d.offered("vercel.cancel", "b1")
    assert cancel is not None and cancel.destructive and cancel.confirm
    assert d.offered("vercel.redeploy", "e1|site|") is not None
    assert not [a for s in d.sections for i in s.items for a in i.actions if "c1" in a.target]
    assert {s.label: s.value for s in d.stats} == {"Ready": "2", "Building": "1", "Failed": "1", "Projects": "1"}
    assert d.sections[1].title == "Projects · 1"


def test_perform_redeploy_promote_cancel():
    http = (FakeHttp().add("POST", "https://api.vercel.com/v13/deployments", {"url": "site-new.vercel.app"})
            .add("PATCH", "https://api.vercel.com/v12/deployments/b1/cancel", {}))
    s = VercelService()
    assert s.perform(http, cfg(), "vercel.redeploy", "p1|site|production") == "Building site-new.vercel.app"
    assert http.calls[-1].json == {"name": "site", "deploymentId": "p1", "target": "production"}
    s.perform(http, cfg(), "vercel.redeploy", "v1|site|")
    assert http.calls[-1].json == {"name": "site", "deploymentId": "v1"}
    s.perform(http, cfg(), "vercel.promote", "v1|site")
    assert http.calls[-1].json == {"deploymentId": "v1", "name": "site", "target": "production",
                                   "meta": {"action": "promote"}}
    assert s.perform(http, cfg(), "vercel.cancel", "b1") == "Build canceled"
    assert http.calls[-1].method == "PATCH"
    with pytest.raises(ServiceError):
        s.perform(http, cfg(), "vercel.cancel", "../x")
