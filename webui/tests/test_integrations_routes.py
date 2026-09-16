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


def test_an_id_that_belongs_to_another_handler_is_refused(reg, sent):
    """A space called photon could be listed but never opened, paused or deleted."""
    assert post("/api/integrations", {"name": "Photon"}) is True
    assert sent["status"] == 400 and "photon" in sent["body"]["error"]
    assert reg.exists("photon") is False


def test_a_name_becomes_a_usable_id(reg, sent):
    assert post("/api/integrations", {"name": "Gym Sessions", "id": "Gym Sessions!"}) is True
    assert sent["body"]["id"] == "gym-sessions"


def test_a_collection_can_be_dropped_on_its_own(reg, sent):
    space = reg.space("casino", name="Casino")
    space.append("sessions", {"net": 1})
    space.append("sessions", {"net": 2})
    space.append("tips", {"amount": 5})

    assert delete("/api/integrations/casino/collections/sessions") is True
    assert sent["body"]["records_removed"] == 2
    assert [c["name"] for c in reg.open("casino").collections()] == ["tips"]


def test_a_document_can_be_dropped_on_its_own(reg, sent):
    space = reg.space("casino", name="Casino")
    space.put("summary", {"net": 157})

    assert delete("/api/integrations/casino/documents/summary") is True
    assert sent["body"]["ok"] is True
    assert reg.open("casino").documents() == []

    assert delete("/api/integrations/casino/documents/summary") is True
    assert sent["status"] == 404


def test_a_skill_is_unlinked_by_default_and_filed_away_on_request(reg, sent, monkeypatch):
    reg.space("casino", name="Casino")
    calls: list = []
    monkeypatch.setattr("jarvis_registry.integrations.unlink_skill",
                        lambda name: calls.append(("unlink", name)) or True)
    monkeypatch.setattr("jarvis_registry.integrations.delete_skill",
                        lambda name: calls.append(("file", name)) or "/somewhere/casino-1")

    assert delete("/api/integrations/casino/skills/casino-earnings-tracker") is True
    assert sent["body"]["unlinked"] is True

    assert delete("/api/integrations/casino/skills/casino-earnings-tracker?mode=file") is True
    assert sent["body"]["moved_to"] == "/somewhere/casino-1"
    assert calls == [("unlink", "casino-earnings-tracker"), ("file", "casino-earnings-tracker")]

    assert delete("/api/integrations/casino/skills/x?mode=shred") is True
    assert sent["status"] == 400


def test_deleting_the_integration_takes_only_the_parts_asked_for(reg, sent, monkeypatch):
    space = reg.space("casino", name="Casino")
    space.append("sessions", {"net": 1})
    space.put("summary", {"net": 1})
    monkeypatch.setattr("cron.jobs.list_jobs",
                        lambda include_disabled=False: [
                            {"id": "abc", "name": "casino-nightly", "integration": "casino"}])
    removed: list = []
    monkeypatch.setattr("cron.jobs.remove_job", lambda job_id: removed.append(job_id) or True)

    # Data only: the schedules and the space itself survive.
    assert routes.handle_delete(object(), urlparse("/api/integrations/casino"),
                                {"data": True, "schedules": False,
                                 "skills": False, "space": False}) is True
    assert sent["body"]["collections_removed"] == ["sessions"]
    assert removed == []
    assert reg.exists("casino") is True
    assert reg.open("casino").collections() == []


def test_a_bare_delete_still_takes_everything(reg, sent, monkeypatch):
    reg.space("casino", name="Casino").append("sessions", {"net": 1})
    monkeypatch.setattr("cron.jobs.list_jobs",
                        lambda include_disabled=False: [
                            {"id": "abc", "name": "casino-nightly", "integration": "casino"}])
    monkeypatch.setattr("cron.jobs.remove_job", lambda job_id: True)

    assert delete("/api/integrations/casino") is True
    assert sent["body"]["schedules_removed"] == ["casino-nightly"]
    assert sent["body"]["deleted"] is True
    assert reg.exists("casino") is False


def test_every_part_of_an_integration_has_its_own_delete_in_the_ui():
    """The panel has to be able to remove one thing without removing the rest."""
    js = (Path(__file__).resolve().parents[1] / "static" / "integrations.js").read_text()
    for what in ("'collection'", "'document'", "'schedule'", "'skill'"):
        assert f"data.del === {what}" in js or f"_intgDeleteButton({what}" in js, what
    # A skill is a choice, never a single destructive button.
    assert "showChoiceDialog" in js and "Remove from this integration" in js
    # And the whole-integration delete asks which parts.
    assert "_intgDeleteSheet" in js and '"space"' not in js.split("_intgDeleteSheet")[0][-200:]
