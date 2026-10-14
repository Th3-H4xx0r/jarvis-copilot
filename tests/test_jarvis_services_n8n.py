"""n8n: latest execution every 15 s (/api/v1 then /rest), run history, failure events,
workflow actions."""
from __future__ import annotations

import pytest

from jarvis_services.base import HttpError
from jarvis_services.config import ConfigView
from jarvis_services.n8n import N8nService
from jarvis_services.testing import FakeHttp

NOW = 1_791_936_000.0  # 2026-10-14 00:00 UTC
BASE = "https://n8n.example.com"
KEY = "n8n_api_key_123"


def cfg(workflows=(), url=BASE + "/"):
    return ConfigView({"SERVICES_N8N_API_KEY": KEY}, {"n8n": {"url": url, "workflows": list(workflows)}},
                      environ={})


def execution(eid, status="success", finished=True):
    return {"id": eid, "finished": finished, "mode": "trigger", "status": status,
            "startedAt": "2026-10-13T10:00:00.000Z", "workflowId": "wf1"}


DETAIL_OK = {"id": "41", "workflowData": {"name": "Sync CRM"},
             "data": {"resultData": {"lastNodeExecuted": "Slack", "runData": {"Slack": [
                 {"data": {"main": [[{"json": {"ok": True, "channel": "C1"}}]]}}]}}}}
DETAIL_ERR = {"id": "42", "workflowData": {"name": "Sync CRM"},
              "data": {"resultData": {"error": {"message": "401 Unauthorized", "node": {"name": "HubSpot"}}}}}


def http_for(latest, detail, api_v1=True):
    http = FakeHttp()
    listing = {"data": [latest], "nextCursor": None}
    if api_v1:
        http.add("GET", f"{BASE}/api/v1/executions?limit=1&includeData=false", listing)
    else:
        http.add("GET", f"{BASE}/api/v1/executions?limit=1&includeData=false", {"message": "nope"}, status=404)
        http.add("GET", f"{BASE}/rest/executions?limit=1&includeData=false", [latest])
    http.add("GET", f"{BASE}/api/v1/executions/{latest['id']}?includeData=true", detail)
    return http


def test_configured_needs_url_and_key():
    s = N8nService()
    assert s.interval == 15
    assert s.configured(cfg())
    assert not s.configured(cfg(url=""))
    assert not s.configured(ConfigView({}, {"n8n": {"url": BASE}}, environ={}))


def test_new_success_run_is_recorded_with_its_output():
    http = http_for(execution("41"), DETAIL_OK)
    snap = N8nService().fetch(http, cfg(), None, NOW)
    assert http.calls[0].headers == {"X-N8N-API-KEY": KEY, "Accept": "application/json"}
    assert snap.tone == "ok" and snap.reason == "Last run succeeded: Sync CRM"
    assert snap.headline == "All recent runs succeeded"
    item = snap.sections[0].items[0]
    assert item.title == "Sync CRM"
    assert item.subtitle.startswith("→ Slack · 1 item\nok: true\nchannel: C1")


def test_falls_back_to_rest_executions():
    http = http_for(execution("41"), DETAIL_OK, api_v1=False)
    snap = N8nService().fetch(http, cfg(), None, NOW)
    assert snap.sections[0].items[0].title == "Sync CRM"
    assert http.called("GET", f"{BASE}/rest/executions")


def test_all_list_endpoints_failing_raises():
    http = FakeHttp().add("GET", f"{BASE}/api/v1/executions", {"message": "bad key"}, status=401)
    http.add("GET", f"{BASE}/rest/executions", {"message": "bad key"}, status=401)
    with pytest.raises(HttpError) as e:
        N8nService().fetch(http, cfg(), None, NOW)
    assert e.value.status == 401


def test_running_execution_is_not_recorded_and_same_id_is_skipped():
    s = N8nService()
    first = s.fetch(http_for(execution("41"), DETAIL_OK), cfg(), None, NOW)
    running = s.fetch(http_for(execution("43", status="running", finished=False), DETAIL_OK), cfg(), first, NOW)
    assert len(running.sections[0].items) == 1
    http = http_for(execution("41"), DETAIL_OK)
    again = s.fetch(http, cfg(), running, NOW)
    assert len(again.sections[0].items) == 1
    assert not http.called("GET", f"{BASE}/api/v1/executions/41")     # no detail re-fetch


def test_failure_event_and_history_cap():
    s = N8nService()
    first = s.fetch(http_for(execution("41"), DETAIL_OK), cfg(), None, NOW)
    assert s.events(None, first.state) == []
    failed = s.fetch(http_for(execution("42", status="error"), DETAIL_ERR), cfg(), first, NOW)
    events = s.events(first.state, failed.state)
    assert [(e.kind, e.title, e.body) for e in events] == [("workflow_failed", "Workflow failed",
                                                             "Sync CRM · HubSpot: 401 Unauthorized")]
    assert failed.tone == "error" and failed.headline == "1 failed run"
    prev = failed
    for i in range(12):
        prev = s.fetch(http_for(execution(str(100 + i)), DETAIL_OK), cfg(), prev, NOW)
    assert len(prev.sections[0].items) == 10


def test_workflow_filter():
    snap = N8nService().fetch(http_for(execution("41"), DETAIL_OK), cfg(workflows=["Other"]), None, NOW)
    assert snap.sections == [] and snap.tone == "idle"


def test_detail_offers_workflow_and_retry_actions():
    http = (FakeHttp()
            .add("GET", f"{BASE}/api/v1/workflows?limit=250", {"data": [
                {"id": "wf1", "name": "Sync CRM", "active": True, "updatedAt": "2026-10-12T10:00:00Z"},
                {"id": "wf2", "name": "Digest", "active": False, "updatedAt": "2026-10-11T10:00:00Z"},
                {"id": "wf3", "name": "Old", "active": False, "isArchived": True}], "nextCursor": None})
            .add("GET", f"{BASE}/api/v1/executions?limit=15", {"data": [
                execution("42", status="error"), execution("41")]}))
    d = N8nService().detail(http, cfg(), NOW)
    off = d.offered("n8n.deactivate", "wf1")
    assert off is not None and off.destructive and off.confirm
    assert d.offered("n8n.activate", "wf2") is not None
    assert d.offered("n8n.activate", "wf3") is None                    # archived
    assert d.offered("n8n.retry", "42") is not None
    assert d.offered("n8n.retry", "41") is None
    assert {s.label: s.value for s in d.stats} == {"Workflows": "2", "Active": "1", "Failed runs": "1"}


@pytest.mark.parametrize("kind,target,url", [
    ("n8n.activate", "wf2", f"{BASE}/api/v1/workflows/wf2/activate"),
    ("n8n.deactivate", "wf1", f"{BASE}/api/v1/workflows/wf1/deactivate"),
    ("n8n.retry", "42", f"{BASE}/api/v1/executions/42/retry"),
])
def test_perform(kind, target, url):
    http = FakeHttp().add("POST", url, {})
    N8nService().perform(http, cfg(), kind, target)
    assert http.calls[0].url == url and http.calls[0].headers["X-N8N-API-KEY"] == KEY


def test_retry_on_old_n8n_explains():
    http = FakeHttp().add("POST", f"{BASE}/api/v1/executions/42/retry", {"message": "x"}, status=404)
    with pytest.raises(Exception) as e:
        N8nService().perform(http, cfg(), "n8n.retry", "42")
    assert "1.112" in str(e.value)
