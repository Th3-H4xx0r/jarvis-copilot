"""it_task: any chat hands a multi-step PC job (or deep research) to the IT agent, which runs as a
Background job; the turn stops after one line."""
import json
from types import SimpleNamespace

from tools import it_task_tool as T

NOTE = ("The IT agent is on it in the background (progress card in this chat; admin steps ask your Face ID on "
        "your iPhone). Tell the user that in one short line and stop.")


def test_it_task_starts_job_and_tells_model_to_stop(monkeypatch):
    from agent import escalation
    marked, started = [], []
    monkeypatch.setattr(T, "_start", lambda task_id, goal: started.append((task_id, goal)) or {"ok": True, "job_id": "j1"})
    monkeypatch.setattr(escalation, "mark_handed_off", lambda tid: marked.append(tid))
    out = json.loads(T.handle_it_task({"goal": "install Docker Desktop"}, task_id="t1"))
    assert out == {"ok": True, "job_id": "j1", "note": NOTE}
    assert marked == ["t1"] and started == [("t1", "install Docker Desktop")]


def test_it_task_reports_start_errors_without_handing_off(monkeypatch):
    from agent import escalation
    marked = []
    monkeypatch.setattr(T, "_start", lambda task_id, goal: {"ok": False, "error": "No PC with Jarvis is paired."})
    monkeypatch.setattr(escalation, "mark_handed_off", lambda tid: marked.append(tid))
    assert json.loads(T.handle_it_task({"goal": "x"}, task_id="t1")) == {"ok": False, "error": "No PC with Jarvis is paired."}
    assert marked == []


def test_it_task_requires_goal():
    assert json.loads(T.handle_it_task({}, task_id="t1")) == {"ok": False, "error": "goal is required"}


def test_it_task_is_core_and_has_its_toolset():
    import toolsets
    assert "it_task" in toolsets._HERMES_CORE_TOOLS and toolsets.TOOLSETS["it_task"]["tools"] == ["it_task"]


def test_it_task_allowed_on_list_nodes_not_none():
    from agent.tool_policy import block_message
    assert block_message(SimpleNamespace(allowed_tool_names={"web_search"}), "it_task", {}) is None
    assert block_message(SimpleNamespace(allowed_tool_names=None), "it_task", {}) is None
    assert block_message(SimpleNamespace(allowed_tool_names=frozenset()), "it_task", {})


def test_it_task_uncounted_by_auto_handoff():
    from agent import escalation
    assert "it_task" in escalation._UNCOUNTED


def test_check_it_task_reads_the_stored_catalog(monkeypatch):
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "webui"))
    from api import device_bridge
    monkeypatch.setattr(device_bridge, "catalog_device_skills", lambda: [{"device_id": "pc", "name": "pc_shell"}])
    assert T.check_it_task() is True
    monkeypatch.setattr(device_bridge, "catalog_device_skills", lambda: [{"device_id": "mac", "name": "ui_look"}])
    assert T.check_it_task() is False
