"""A scheduled job runs inside its integration: it gets the catalog and the skills."""
from __future__ import annotations

import pytest

import jarvis_registry.store as store
from cron.scheduler import _build_job_prompt
from jarvis_registry import Registry


@pytest.fixture()
def casino(tmp_path, monkeypatch):
    reg = Registry(tmp_path / "registry.db")
    monkeypatch.setattr(store, "shared", lambda: reg)
    space = reg.space("casino", name="Casino Earnings", description="Visits and earnings")
    space.append("sessions", {"net": 40})
    space.collection("sessions").describe("one casino visit")

    root = tmp_path / "skills"
    (root / "productivity" / "casino-earnings-tracker").mkdir(parents=True)
    (root / "productivity" / "casino-earnings-tracker" / "SKILL.md").write_text(
        "---\nname: casino-earnings-tracker\ndescription: Log sessions.\nintegration: casino\n---\n")
    import tools.skills_tool as skills_tool

    monkeypatch.setattr(skills_tool, "SKILLS_DIR", root)
    yield reg
    reg.close()


def test_the_prompt_carries_the_integration_catalog(casino):
    prompt = _build_job_prompt({"id": "1", "name": "casino-nightly", "integration": "casino",
                                "prompt": "Summarise last night."})
    assert 'space id "casino"' in prompt
    assert "sessions (1 records) — one casino visit" in prompt
    assert "Summarise last night." in prompt


def test_the_integrations_own_skills_load_without_being_listed(casino, monkeypatch):
    loaded: list[str] = []

    def fake_skill_view(name, *a, **k):
        loaded.append(name)
        return '{"success": true, "content": "# ' + name + '"}'

    import tools.skills_tool as skills_tool

    monkeypatch.setattr(skills_tool, "skill_view", fake_skill_view)
    monkeypatch.setattr("tools.skill_usage.bump_use", lambda *a, **k: None)

    prompt = _build_job_prompt({"id": "1", "name": "casino-nightly", "integration": "casino",
                                "prompt": "Summarise last night."})
    assert loaded == ["casino-earnings-tracker"]
    assert "# casino-earnings-tracker" in prompt


def test_a_job_with_no_integration_is_unchanged(casino):
    prompt = _build_job_prompt({"id": "2", "name": "Reminder", "prompt": "Ping me."})
    assert "Integration:" not in prompt
    assert "Ping me." in prompt


def test_the_cronjob_tool_files_a_schedule_under_its_integration(monkeypatch):
    """Without this the setup agent's schedules all land in `general` and never
    appear on the integration it just built.

    Asserts the value reaches create_job, not what the tool answers — the reply is
    built from the stored job, which is not what this is about.
    """
    import tools.cronjob_tools as ct

    captured: dict = {}

    def fake_create_job(**kwargs):
        captured.update(kwargs)
        return {"id": "j1", "name": kwargs.get("name")}

    # cronjob_tools imports create_job at module level, so patch it there.
    monkeypatch.setattr("tools.cronjob_tools.create_job", fake_create_job)
    ct.cronjob(action="create", prompt="Summarise the week.", schedule="every 30m",
               name="gym-weekly", integration="gym-sessions")
    assert captured["integration"] == "gym-sessions"


def test_the_tool_advertises_the_parameter_it_reads():
    """A parameter the model cannot see is a parameter it will never pass."""
    from tools.registry import discover_builtin_tools, registry

    discover_builtin_tools()
    props = (registry.get_schema("cronjob") or {}).get("parameters", {}).get("properties", {})
    assert "integration" in props
