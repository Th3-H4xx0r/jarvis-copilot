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


def test_the_list_says_how_much_each_one_holds(reg):
    space = reg.space("casino", name="Casino")
    space.put("summary", {"net": 157})
    space.append("sessions", {"net": 40})
    space.append("sessions", {"net": -12})

    row = next(r for r in integrations.overview() if r["id"] == "casino")
    assert (row["collection_count"], row["record_count"], row["document_count"]) == (1, 2, 1)


def test_a_schedule_row_leaves_the_prompt_behind(reg, monkeypatch):
    reg.space("casino", name="Casino")
    monkeypatch.setattr("cron.jobs.list_jobs", lambda include_disabled=False: [
        {"id": "j1", "name": "casino-nightly", "integration": "casino",
         "schedule": {"kind": "cron", "expr": "0 9 * * *"}, "enabled": True,
         "prompt": "a very long prompt " * 200, "next_run": 1700}])

    row = integrations.summary("casino")["schedules"][0]
    assert row == {"id": "j1", "name": "casino-nightly",
                   "schedule": {"kind": "cron", "expr": "0 9 * * *"},
                   "enabled": True, "state": None, "last_run": None, "next_run": 1700}


def test_the_migrations_bookkeeping_is_not_data_the_integration_keeps(reg):
    space = reg.space("casino", name="Casino")
    space.put("summary", {"net": 157})
    space.put("imported_files", {"casino/ledger.csv": {"sha": "abc"}})

    assert [d["key"] for d in integrations.summary("casino")["documents"]] == ["summary"]
    block = integrations.context_block("casino")
    assert "summary" in block and "imported_files" not in block


def test_a_schedule_row_carries_the_times_cron_actually_records(reg, monkeypatch):
    """Cron writes next_run_at / last_run_at; there are no next_run / last_run keys."""
    reg.space("casino", name="Casino")
    monkeypatch.setattr("cron.jobs.list_jobs", lambda include_disabled=False: [
        {"id": "j1", "name": "nightly", "integration": "casino",
         "next_run_at": "2026-09-16T01:30:00+00:00",
         "last_run_at": "2026-09-16T01:15:53+00:00"}])

    row = integrations.summary("casino")["schedules"][0]
    assert row["next_run"] == "2026-09-16T01:30:00+00:00"
    assert row["last_run"] == "2026-09-16T01:15:53+00:00"
    assert next(r for r in integrations.overview() if r["id"] == "casino")["last_run"]


def test_a_skill_is_named_the_way_a_run_has_to_address_it(reg, skills_dir, monkeypatch):
    """skill_view resolves a skill by directory name; a front-matter name is a label."""
    (skills_dir / "productivity" / "odd-name").mkdir(parents=True)
    (skills_dir / "productivity" / "odd-name" / "SKILL.md").write_text(
        "---\nname: a-completely-different-label\ndescription: Does a thing.\n"
        "integration: casino\n---\n")
    reg.space("casino", name="Casino")

    skills = {s["name"]: s for s in integrations.skills_for("casino")}
    assert "odd-name" in skills                       # the directory, which resolves
    assert skills["odd-name"]["title"] == "a-completely-different-label"


def test_a_skill_can_stop_belonging_without_being_deleted(reg, skills_dir):
    reg.space("casino", name="Casino")
    assert [s["name"] for s in integrations.skills_for("casino")] == ["casino-earnings-tracker"]

    assert integrations.unlink_skill("casino-earnings-tracker") is True
    assert integrations.skills_for("casino") == []
    # The skill itself is untouched.
    assert integrations.skill_path("casino-earnings-tracker") is not None
    assert integrations.unlink_skill("casino-earnings-tracker") is False   # already unlinked
    assert integrations.unlink_skill("no-such-skill") is False


def test_a_deleted_skill_is_moved_somewhere_nothing_loads_it(reg, skills_dir, tmp_path,
                                                             monkeypatch):
    monkeypatch.setattr(integrations, "_home", lambda: str(tmp_path / "home"))
    reg.space("casino", name="Casino")

    where = integrations.delete_skill("casino-earnings-tracker")
    assert where is not None
    from pathlib import Path

    moved = Path(where)
    assert (moved / "SKILL.md").exists()          # recoverable, not shredded
    assert not moved.is_relative_to(skills_dir)   # and out of the tree that gets globbed
    assert integrations.skill_path("casino-earnings-tracker") is None
    assert integrations.skills_for("casino") == []
    assert integrations.delete_skill("casino-earnings-tracker") is None
