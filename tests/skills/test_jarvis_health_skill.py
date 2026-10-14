"""The health skill's habit commands: what chat sends to Jarvis Health.

The script's one network call (`request`) is replaced by a recorder that
answers from canned rows, so nothing leaves the process.
"""
from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SKILL_DIR = REPO_ROOT / "skills" / "jarviscopilot" / "health"
SKILL_MD = SKILL_DIR / "SKILL.md"
SCRIPT_PATH = SKILL_DIR / "scripts" / "health.py"
BASE = "/api/integrations/jarvis-health/health"


def _load():
    spec = importlib.util.spec_from_file_location("jarvis_health_skill", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class Recorder:
    def __init__(self):
        self.made = []
        self.answers = {}

    def __call__(self, method, path, body=None, timeout=45):
        self.made.append((method, path, body))
        return self.answers.get(f"{method} {path.split('?')[0]}", (200, {"ok": True}))


@pytest.fixture
def calls():
    return Recorder()


@pytest.fixture
def skill(calls, monkeypatch):
    module = _load()
    monkeypatch.setattr(module, "request", calls)
    return module


def _habits(calls, *habits):
    calls.answers[f"GET {BASE}/habits"] = (200, {"habits": list(habits)})


def test_a_relapse_is_logged_against_the_habit_found_by_name(skill, calls):
    _habits(calls, {"id": "scroll-1a2b3c", "name": "Doomscrolling", "goal": {"streak_days": 30, "limit": None}})
    assert skill.main(["habit-relapse", "--habit", "doomscrolling", "--at", "2026-10-14T03:00:00Z"]) == 0
    assert calls.made[-1] == ("POST", f"{BASE}/habits/relapse",
                              {"habit": "scroll-1a2b3c", "at": "2026-10-14T03:00:00Z"})


def test_an_update_sends_the_whole_goal(skill, calls):
    _habits(calls, {"id": "h", "name": "Vape", "goal": {"streak_days": 30, "limit": {"per": "day", "count": 2}}})
    assert skill.main(["habit-update", "--habit", "h", "--no-limit"]) == 0
    assert calls.made[-1] == ("POST", f"{BASE}/habits", {"habit": {"id": "h", "goal": {"streak_days": 30, "limit": None}}})
    assert skill.main(["habit-update", "--habit", "h", "--name", "Vaping"]) == 0
    assert calls.made[-1][2] == {"habit": {"id": "h", "name": "Vaping"}}


def test_create_carries_a_monthly_limit(skill, calls):
    assert skill.main(["habit-create", "--name", "Sugar", "--limit", "3", "--per", "month", "--streak-days", "14"]) == 0
    assert calls.made[-1] == ("POST", f"{BASE}/habits", {"habit": {
        "name": "Sugar", "goal": {"streak_days": 14, "limit": {"per": "month", "count": 3}}}})


def test_undo_delete_and_days_use_the_habits_id(skill, calls):
    _habits(calls, {"id": "h", "name": "Vape"})
    assert skill.main(["habit-undo", "--habit", "Vape"]) == 0
    assert calls.made[-1] == ("POST", f"{BASE}/habits/relapse/delete", {"habit": "h", "latest": True})
    assert skill.main(["habit-delete", "--habit", "h"]) == 0
    assert calls.made[-1] == ("POST", f"{BASE}/habits/delete", {"id": "h"})
    assert skill.main(["habit-days", "--habit", "h", "--days", "7"]) == 0
    assert calls.made[-1] == ("GET", f"{BASE}/habits/days?id=h&days=7", None)


def test_an_ambiguous_habit_fails_and_names_them(skill, calls, capsys):
    _habits(calls, {"id": "a", "name": "Vape"}, {"id": "b", "name": "Vape less"})
    assert skill.main(["habit-undo", "--habit", "vap"]) == 1
    err = capsys.readouterr().err
    assert "Vape (a)" in err and "Vape less (b)" in err
    assert all(method == "GET" for method, _, _ in calls.made)


def test_skill_md_describes_habits_briefly():
    text = SKILL_MD.read_text()
    description = re.search(r"^description: (.*)$", text, re.MULTILINE).group(1)
    assert len(description) <= 60 and description.endswith(".")
    assert "habit-relapse" in text
