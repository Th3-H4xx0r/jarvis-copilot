"""The Integrations HTTP surface: list, detail, records, status, delete."""
from __future__ import annotations

import sys
from pathlib import Path
from urllib.parse import urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.helpers as helpers  # noqa: E402
import api.integrations_routes as routes  # noqa: E402
import jarvis_registry.store as store  # noqa: E402
from jarvis_registry import Registry  # noqa: E402


@pytest.fixture()
def sent(monkeypatch):
    """Captures what the handler would have written."""
    box: dict = {}

    def fake_j(handler, body, status=200):
        box["body"] = body
        box["status"] = status
        return True

    monkeypatch.setattr(helpers, "j", fake_j)
    return box


@pytest.fixture()
def reg(tmp_path, monkeypatch):
    r = Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store, "shared", lambda: r)
    monkeypatch.setattr("cron.jobs.list_jobs", lambda include_disabled=False: [])
    yield r
    r.close()


def get(path):
    return routes.handle_get(object(), urlparse(path))


def post(path, body):
    return routes.handle_post(object(), urlparse(path), body)


def delete(path):
    return routes.handle_delete(object(), urlparse(path))


def test_the_list_includes_general_even_on_a_fresh_install(reg, sent):
    assert get("/api/integrations") is True
    ids = [i["id"] for i in sent["body"]["integrations"]]
    assert ids == ["general"]


def test_create_then_read_one(reg, sent):
    assert post("/api/integrations", {"name": "Casino Earnings",
                                      "description": "Visits and earnings"}) is True
    assert sent["status"] == 201
    assert sent["body"]["id"] == "casino-earnings"

    reg.open("casino-earnings").append("sessions", {"net": 40}, ts=1000)
    assert get("/api/integrations/casino-earnings") is True
    body = sent["body"]
    assert body["name"] == "Casino Earnings"
    assert body["collections"][0]["name"] == "sessions"
    assert body["schedule_count"] == 0


def test_create_needs_a_name(reg, sent):
    assert post("/api/integrations", {"description": "no name"}) is True
    assert sent["status"] == 400 and "name" in sent["body"]["error"]


def test_records_come_back_filtered(reg, sent):
    space = reg.space("casino", name="Casino")
    space.append("sessions", {"net": 1}, ts=1000)
    space.append("sessions", {"net": 2}, ts=2000)

    assert get("/api/integrations/casino/records?collection=sessions") is True
    assert sent["body"]["count"] == 2

    assert get("/api/integrations/casino/records?collection=sessions&since=1500") is True
    assert [r["net"] for r in sent["body"]["records"]] == [2]

    assert get("/api/integrations/casino/records") is True
    assert sent["status"] == 400


def test_an_unknown_integration_is_a_404(reg, sent):
    assert get("/api/integrations/ghost") is True
    assert sent["status"] == 404

    assert post("/api/integrations/ghost/status", {"status": "paused"}) is True
    assert sent["status"] == 404


def test_pausing_and_a_bad_status(reg, sent):
    reg.space("casino", name="Casino")
    assert post("/api/integrations/casino/status", {"status": "paused"}) is True
    assert sent["body"]["status"] == "paused"
    assert reg.open("casino").info()["status"] == "paused"

    assert post("/api/integrations/casino/status", {"status": "sleepy"}) is True
    assert sent["status"] == 400


def test_deleting_takes_the_schedules_with_it(reg, sent, monkeypatch):
    reg.space("casino", name="Casino").append("sessions", {"net": 1})
    monkeypatch.setattr("cron.jobs.list_jobs",
                        lambda include_disabled=False: [
                            {"id": "abc", "name": "casino-nightly", "integration": "casino"}])
    removed: list[str] = []
    monkeypatch.setattr("cron.jobs.remove_job", lambda job_id: removed.append(job_id) or True)

    assert delete("/api/integrations/casino") is True
    assert sent["body"]["schedules_removed"] == ["casino-nightly"]
    assert removed == ["abc"]
    assert reg.exists("casino") is False


def test_paths_that_are_not_ours_fall_through(reg, sent):
    assert get("/api/devices") is False
    assert post("/api/devices", {}) is False
    assert delete("/api/devices/abc") is False


def test_the_photon_setup_endpoint_is_not_a_space(reg, sent):
    """/api/integrations/photon is the iMessage provider's config, not an integration."""
    assert get("/api/integrations/photon") is False
    assert post("/api/integrations/photon", {"host": "x"}) is False
    assert delete("/api/integrations/photon") is False


def test_a_document_can_be_opened_on_its_own(reg, sent):
    space = reg.space("casino", name="Casino")
    space.put("summary", {"net": 157}, description="totals so far")

    assert get("/api/integrations/casino/documents/summary") is True
    assert sent["body"]["body"] == {"net": 157}
    assert sent["body"]["description"] == "totals so far"

    assert get("/api/integrations/casino/documents/ghost") is True
    assert sent["status"] == 404
