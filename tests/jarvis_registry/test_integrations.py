"""Integrations: a space plus the skills and schedules that belong to it."""
from __future__ import annotations

import pytest

import jarvis_registry.integrations as integrations
import jarvis_registry.store as store
from jarvis_registry import Registry


@pytest.fixture()
def reg(tmp_path, monkeypatch):
    r = Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store, "shared", lambda: r)
    yield r
    r.close()


@pytest.fixture()
def skills_dir(tmp_path, monkeypatch):
    root = tmp_path / "skills"
    (root / "productivity" / "casino-earnings-tracker").mkdir(parents=True)
    (root / "productivity" / "casino-earnings-tracker" / "SKILL.md").write_text(
        "---\nname: casino-earnings-tracker\ndescription: Log casino sessions.\n"
        "integration: casino\n---\n\n# Casino\n")
    (root / "media" / "vibeforge").mkdir(parents=True)
    (root / "media" / "vibeforge" / "SKILL.md").write_text(
        "---\nname: vibeforge\ndescription: Music taste.\nintegration: vibeforge\n---\n")
    (root / "media" / "loose").mkdir(parents=True)
    (root / "media" / "loose" / "SKILL.md").write_text(
        "---\nname: loose\ndescription: Belongs to nobody.\n---\n")
    import tools.skills_tool as skills_tool

    monkeypatch.setattr(skills_tool, "SKILLS_DIR", root)
    return root


def test_skills_follow_their_integration(reg, skills_dir):
    reg.space("casino", name="Casino Earnings")
    owned = integrations.skills_for("casino")
    assert [s["name"] for s in owned] == ["casino-earnings-tracker"]
    assert owned[0]["description"] == "Log casino sessions."

    assert [s["name"] for s in integrations.skills_for("vibeforge")] == ["vibeforge"]
    assert integrations.skills_for("nobody") == []
    assert integrations.owner_of_skill("casino-earnings-tracker") == "casino"
    assert integrations.owner_of_skill("loose") is None


def test_schedules_group_by_integration_and_untagged_land_in_general(reg, monkeypatch):
    jobs = [
        {"id": "1", "name": "vibeforge-scan", "integration": "vibeforge", "enabled": True,
         "last_run": 300},
        {"id": "2", "name": "casino-nightly", "integration": "casino", "enabled": True,
         "last_run": 100},
        {"id": "3", "name": "Reminder", "enabled": False},          # no integration
    ]
    monkeypatch.setattr("cron.jobs.list_jobs", lambda include_disabled=False: list(jobs))

    assert [j["name"] for j in integrations.schedules_for("vibeforge")] == ["vibeforge-scan"]
    assert [j["name"] for j in integrations.schedules_for("general")] == ["Reminder"]

    reg.space("vibeforge", name="VibeForge")
    reg.space("casino", name="Casino")
    integrations.ensure_general()
    rows = {r["id"]: r for r in integrations.overview()}
    assert rows["vibeforge"]["schedule_count"] == 1
    assert rows["vibeforge"]["enabled_schedule_count"] == 1
    assert rows["vibeforge"]["last_run"] == 300
    assert rows["general"]["schedule_count"] == 1
    assert rows["general"]["enabled_schedule_count"] == 0
    assert rows["casino"]["last_run"] == 100


def test_a_run_is_told_what_its_integration_holds(reg, skills_dir):
    space = reg.space("casino", name="Casino Earnings", description="Visits and earnings")
    space.append("sessions", {"net": 40})
    space.collection("sessions").describe("one casino visit")
    space.put("settings", {"bankroll": 500}, description="Starting money")

    block = integrations.context_block("casino")
    assert 'space id "casino"' in block
    assert "Visits and earnings" in block
    assert "sessions (1 records) — one casino visit" in block
    assert "settings — Starting money" in block
    assert "casino-earnings-tracker" in block
    assert "registry_append" in block          # it says how to write, not just what exists


def test_no_integration_means_no_context(reg):
    assert integrations.context_block("") == ""
    assert integrations.context_block("ghost") == ""


def test_summary_carries_everything_the_page_needs(reg, skills_dir, monkeypatch):
    monkeypatch.setattr("cron.jobs.list_jobs",
                        lambda include_disabled=False: [
                            {"id": "1", "name": "casino-nightly", "integration": "casino"}])
    space = reg.space("casino", name="Casino Earnings")
    space.append("sessions", {"net": 1})

    out = integrations.summary("casino")
    assert out["name"] == "Casino Earnings"
    assert out["collections"][0]["name"] == "sessions"
    assert [s["name"] for s in out["skills"]] == ["casino-earnings-tracker"]
    assert out["schedule_count"] == 1


def test_general_is_created_once(reg):
    assert integrations.ensure_general() == "general"
    integrations.ensure_general()
    assert [s["id"] for s in reg.spaces()] == ["general"]
    assert reg.open("general").info()["name"] == "General"
