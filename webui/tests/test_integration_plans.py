"""The plan card: validated, stored pending, and only built on approval."""
from __future__ import annotations

import sys
from pathlib import Path
from urllib.parse import urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import api.helpers as helpers  # noqa: E402
import api.integration_plans as plans  # noqa: E402
import jarvis_registry.store as store  # noqa: E402
from jarvis_registry import Registry  # noqa: E402

GOOD = {
    "name": "Gym Sessions",
    "summary": "Logs your workouts and sums the week.",
    "schedules": [{
        "name": "gym-weekly-summary",
        "schedule": "0 19 * * 0",
        "purpose": "Sunday evening: what you lifted this week.",
        "prompt": "Summarise this week's gym sessions from the registry.",
    }],
    "collections": [{"name": "sessions", "description": "one workout: lifts, sets, how it felt"}],
    "skills": [{"name": "gym-logger", "purpose": "Log a workout from a sentence."}],
}


@pytest.fixture()
def home(tmp_path, monkeypatch):
    monkeypatch.setattr(plans, "_plans_path", lambda: tmp_path / "integration_plans.json")
    reg = Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store, "shared", lambda: reg)
    created: list[dict] = []

    def fake_create_job(prompt, schedule, name=None, integration=None, **kw):
        job = {"id": f"job{len(created)}", "name": name, "schedule": schedule,
               "prompt": prompt, "integration": integration}
        created.append(job)
        return job

    monkeypatch.setattr("cron.jobs.create_job", fake_create_job)
    yield {"reg": reg, "created": created}
    reg.close()


@pytest.fixture()
def sent(monkeypatch):
    box: dict = {}

    def fake_j(handler, body, status=200):
        box["body"] = body
        box["status"] = status
        return True

    monkeypatch.setattr(helpers, "j", fake_j)
    return box


def test_a_good_plan_is_stored_pending_and_creates_nothing(home):
    plan = plans.propose(dict(GOOD))
    assert plan["space_id"] == "gym-sessions" and plan["status"] == "pending"
    assert [p["id"] for p in plans.pending()] == [plan["id"]]
    # Nothing exists yet — that is the whole point of the card.
    assert home["reg"].exists("gym-sessions") is False
    assert home["created"] == []


def test_the_bad_field_is_named(home):
    with pytest.raises(plans.PlanError, match="name is required"):
        plans.propose({"summary": "no name"})
    with pytest.raises(plans.PlanError, match=r"schedules\[0\].schedule is required"):
        plans.propose({"name": "X", "summary": "y",
                       "schedules": [{"name": "a", "purpose": "b", "prompt": "c"}]})
    with pytest.raises(plans.PlanError, match="at least one"):
        plans.propose({"name": "X", "summary": "y"})
    with pytest.raises(plans.PlanError, match="at most"):
        plans.propose({"name": "X", "summary": "y",
                       "collections": [{"name": f"c{i}", "description": "d"}
                                       for i in range(plans.MAX_COLLECTIONS + 1)]})


def test_approval_builds_exactly_what_the_card_listed(home):
    plan = plans.propose(dict(GOOD))
    out = plans.approve(plan["id"])

    assert out["space_id"] == "gym-sessions"
    space = home["reg"].open("gym-sessions")
    assert space.info()["name"] == "Gym Sessions"
    assert [c["name"] for c in space.collections()] == ["sessions"]
    assert space.collections()[0]["description"].startswith("one workout")

    assert [j["name"] for j in home["created"]] == ["gym-weekly-summary"]
    assert home["created"][0]["integration"] == "gym-sessions"
    assert plans.get(plan["id"])["status"] == "approved"
    assert plans.pending() == []


def test_a_broken_schedule_does_not_sink_the_rest(home, monkeypatch):
    def half_broken(prompt, schedule, name=None, integration=None, **kw):
        if name == "bad":
            raise ValueError("unparseable schedule")
        return {"id": "ok1", "name": name}

    monkeypatch.setattr("cron.jobs.create_job", half_broken)
    plan = plans.propose({**GOOD, "schedules": [
        {"name": "bad", "schedule": "nonsense", "purpose": "p", "prompt": "q"},
        {"name": "good", "schedule": "0 9 * * *", "purpose": "p", "prompt": "q"},
    ]})
    out = plans.approve(plan["id"])
    assert [s.get("error") is not None for s in out["schedules"]] == [True, False]
    assert home["reg"].exists("gym-sessions") is True


def test_cancelling_leaves_nothing_behind(home):
    plan = plans.propose(dict(GOOD))
    assert plans.cancel(plan["id"]) is True
    assert plans.pending() == []
    assert home["reg"].exists("gym-sessions") is False
    assert plans.cancel(plan["id"]) is False
    with pytest.raises(plans.PlanError, match="already cancelled"):
        plans.approve(plan["id"])


def test_the_http_surface(home, sent):
    plan = plans.propose(dict(GOOD))
    assert plans.handle_get(object(), urlparse("/api/integrations/plans")) is True
    assert [p["id"] for p in sent["body"]["plans"]] == [plan["id"]]

    assert plans.handle_post(object(), urlparse(f"/api/integrations/plans/{plan['id']}/approve"),
                             {}) is True
    assert sent["body"]["space_id"] == "gym-sessions"

    assert plans.handle_post(object(), urlparse("/api/integrations/plans/nope/approve"), {}) is True
    assert sent["status"] == 400

    assert plans.handle_post(object(), urlparse("/api/integrations/plans/nope/cancel"), {}) is True
    assert sent["status"] == 404
