"""Router → Computer: the fast loop runs before any model call."""
import json
from types import SimpleNamespace

import pytest

from agent import mac_browser_gate
from agent.computer import loop as L
from agent.computer import turns


@pytest.fixture(autouse=True)
def _clean():
    mac_browser_gate.reset_for_tests()
    turns.reset_for_tests()
    yield
    mac_browser_gate.reset_for_tests()
    turns.reset_for_tests()


def _agent():
    events = []
    return SimpleNamespace(tool_progress_callback=lambda *a, **k: events.append(a[:2]), events=events)


def _result(status, say=""):
    return L.Result(status, say=say, actions=[{"did": "click button '7'", "by": "decision", "conf": 0.9,
                                               "ms": 700, "via": "ax", "decide_ms": 380}],
                    look={"look_id": "L1", "app": "Calc", "elements": []}, reason="" if status == "done" else "lost")


def test_done_appends_call_result_and_line(monkeypatch):
    mac_browser_gate.note_turn("t1", "on my mac open calculator")
    monkeypatch.setattr(turns, "run_task", lambda goal, steps, task_id, app=None: (_result("done", "Calculator is open."), None))
    agent, messages = _agent(), [{"role": "user", "content": "on my mac open calculator"}]
    said = turns.computer_first(agent, messages, "on my mac open calculator", "t1")
    assert said == "Calculator is open."
    call, result, line = messages[1:]
    assert call["tool_calls"][0]["function"]["name"] == "computer_do"
    assert json.loads(call["tool_calls"][0]["function"]["arguments"]) == {"goal": "on my mac open calculator"}
    assert result["role"] == "tool" and result["tool_call_id"] == call["tool_calls"][0]["id"]
    assert line == {"role": "assistant", "content": "Calculator is open."}
    assert agent.events == [("tool.started", "computer_do"), ("tool.completed", "computer_do")]


def test_stuck_hands_over(monkeypatch):
    mac_browser_gate.note_turn("t1", "on my mac do the thing")
    monkeypatch.setattr(turns, "run_task", lambda goal, steps, task_id, app=None: (_result("stuck"), None))
    messages = [{"role": "user", "content": "x"}]
    assert turns.computer_first(_agent(), messages, "on my mac do the thing", "t1") is None
    assert [m["role"] for m in messages] == ["user", "assistant", "tool"]


def test_computer_first_skipped_without_mac_ask(monkeypatch):
    mac_browser_gate.note_turn("t1", "open calculator")
    monkeypatch.setattr(turns, "run_task", lambda *a: pytest.fail("must not touch the Mac"))
    messages = [{"role": "user", "content": "open calculator"}]
    assert turns.computer_first(_agent(), messages, "open calculator", "t1") is None
    assert len(messages) == 1


def test_no_mac_appends_nothing(monkeypatch):
    mac_browser_gate.note_turn("t1", "on my mac open calculator")
    monkeypatch.setattr(turns, "run_task", lambda *a: (None, "No Mac is online."))
    messages = [{"role": "user", "content": "x"}]
    assert turns.computer_first(_agent(), messages, "on my mac open calculator", "t1") is None
    assert len(messages) == 1


def test_gateway_apply_and_clear_set_the_computer_node():
    from agent.harness.planner import TurnPlan
    from gateway import harness_turns as H
    plan = TurnPlan(harness_id="h", harness_name="H", node_id="big", model="m", provider="p",
                    computer={"id": "mac"}, computer_first=True)
    agent = SimpleNamespace(max_iterations=10, allowed_tool_names=None, _turn_user_context="")
    mp = H.MessagePlan(harness_id="h", harness_name="H", plan=plan, model="m", provider="p", runtime=None)
    H.apply_node(agent, mp, task_id="t", deliver=lambda s: None, platform="telegram", question="q", toolsets=None)
    assert agent._computer_node == {"id": "mac"} and agent._computer_first is True
    H.clear_node(agent)
    assert agent._computer_node is None and agent._computer_first is False
