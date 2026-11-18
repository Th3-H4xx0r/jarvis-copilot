"""it_task joins every webui agent's canonical tools list once (prompt cache), and its card reads right."""
from types import SimpleNamespace

import api.config  # noqa: F401  (puts the agent checkout on sys.path)


def test_canonical_tools_include_it_task_once(monkeypatch):
    from tools import it_task_tool
    monkeypatch.setattr(it_task_tool, "check_it_task", lambda: True)
    from api.streaming import _ensure_canonical_tools
    a = SimpleNamespace(tools=[], valid_tool_names=set())
    _ensure_canonical_tools(a)
    a._canonical_tools_done = False      # even a second pass never adds it twice
    _ensure_canonical_tools(a)
    names = [t["function"]["name"] for t in a.tools]
    assert names.count("it_task") == 1 and "it_task" in a.valid_tool_names


def test_it_task_card_activity():
    import api.harness_runner as hr
    assert hr.tool_activity("it_task") == "Starting an IT task"
