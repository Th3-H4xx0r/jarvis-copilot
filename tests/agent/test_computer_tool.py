"""computer_do: the tool a main model calls to have the fast loop drive the Mac."""
import json

import pytest

from agent.computer import loop as L
from agent.computer import turns


@pytest.fixture(autouse=True)
def _clean():
    turns.reset_for_tests()
    yield
    turns.reset_for_tests()


def test_config_for_uses_the_node_and_falls_back(monkeypatch):
    monkeypatch.setattr("agent.computer.decide.pick_decision_ref", lambda pref: pref or "@auto:decider")
    cfg = turns.config_for({"model": "@celeris:celeris-1-decision", "fallback_model": "@a:haiku",
                            "max_steps": 12, "instructions": "be quick"}, "@a:sonnet")
    assert (cfg.decision_ref, cfg.fallback_ref, cfg.max_actions, cfg.instructions) == \
        ("@celeris:celeris-1-decision", "@a:haiku", 12, "be quick")
    cfg = turns.config_for(None, "@a:sonnet")
    assert (cfg.decision_ref, cfg.fallback_ref, cfg.max_actions) == ("@auto:decider", "@a:sonnet", 30)


def test_bind_and_bound():
    turns.bind("t1", {"id": "c"}, own_ref="@a:m")
    assert turns.bound("t1").node == {"id": "c"} and turns.bound("t1").own_ref == "@a:m"
    assert turns.bound("nope") is None


def test_tool_reports_no_mac(monkeypatch):
    from tools import computer_do_tool as T
    monkeypatch.setattr("agent.computer.mac.find_mac", lambda task_id=None: (None, "", "No Mac is online."))
    out = json.loads(T.handle_computer_do({"goal": "open notes"}, task_id="t1"))
    assert out == {"ok": False, "error": "No Mac is online."}


def test_tool_requires_a_goal():
    from tools import computer_do_tool as T
    assert json.loads(T.handle_computer_do({}, task_id="t1"))["ok"] is False


def test_tool_runs_the_loop_with_the_bound_node(monkeypatch):
    from tools import computer_do_tool as T
    monkeypatch.setattr("agent.computer.mac.find_mac", lambda task_id=None: ("dev1", "MacBook", None))
    monkeypatch.setattr("agent.computer.decide.pick_decision_ref", lambda pref: pref)
    monkeypatch.setattr("tools.vision_tools._model_sees_images", lambda: True)
    seen = {}

    def fake_run(goal, steps, cfg, **kw):
        seen.update(goal=goal, steps=steps, cfg=cfg, device=kw["device"])
        return L.Result("done", say="", actions=[{"did": "click button '7'", "by": "decision", "conf": 0.9,
                                                  "ms": 800, "via": "ax", "decide_ms": 400}],
                        look={"look_id": "L2", "app": "Calc", "window": "Calc", "base64": "QUJD",
                              "mime": "image/jpeg", "elements": [{"i": 1, "role": "AXButton", "label": "7"}]},
                        steps=steps or [])

    monkeypatch.setattr(L, "run", fake_run)
    turns.bind("t1", {"model": "@celeris:celeris-1-decision", "fallback_model": "@a:haiku"}, own_ref="@a:sonnet")
    out = T.handle_computer_do({"goal": "press 7", "steps": [{"do": "press 7"}, {"bad": 1}]}, task_id="t1")
    assert seen["device"] == "dev1" and seen["cfg"].decision_ref == "@celeris:celeris-1-decision"
    assert seen["steps"] == [{"do": "press 7"}]
    assert out["_multimodal"] is True
    assert "Done on" in out["content"][0]["text"]
    assert out["content"][1]["image_url"]["url"] == "data:image/jpeg;base64,QUJD"


def test_tool_policy_lets_computer_do_through_when_a_node_is_bound():
    from types import SimpleNamespace
    from agent.tool_policy import block_message
    agent = SimpleNamespace(allowed_tool_names=frozenset(), _computer_node={"id": "c"})
    assert block_message(agent, "computer_do", {}) is None
    agent = SimpleNamespace(allowed_tool_names=frozenset(), _computer_node=None)
    assert block_message(agent, "computer_do", {}) is not None



def test_the_chat_model_picks_the_computer_and_a_sleeping_one_is_woken(monkeypatch):
    from tools import computer_do_tool as T
    seen = {}
    monkeypatch.setattr("agent.computer.mac.find_mac",
                        lambda task_id=None, prefer="": seen.setdefault("prefer", prefer) and ("pc", "pranav-computer", None))
    monkeypatch.setattr("agent.computer.wake.ensure_awake", lambda did, **kw: seen.setdefault("woke", did) and (True, ""))
    monkeypatch.setattr("agent.computer.decide.pick_decision_ref", lambda pref: pref)
    monkeypatch.setattr("tools.vision_tools._model_sees_images", lambda: False)
    monkeypatch.setattr(L, "run", lambda goal, steps, cfg, **kw: L.Result("done", device_name=kw["device_name"]))
    out = json.loads(T.handle_computer_do({"goal": "launch Warzone", "computer": "PC"}, task_id="t1"))
    assert out["ok"] is True and seen == {"prefer": "PC", "woke": "pc"}


def test_an_app_missing_on_the_mac_is_tried_on_the_pc(monkeypatch):
    # Live 2026-11-19: `open -a Battle.net` failed on the Mac; Battle.net lives on his PC.
    from tools import computer_do_tool as T
    monkeypatch.setattr("agent.computer.mac.find_mac", lambda task_id=None, prefer="": ("mac", "MacBook", None))
    monkeypatch.setattr("agent.computer.mac.other_computer", lambda device, task_id=None: ("pc", "pranav-computer"))
    monkeypatch.setattr("agent.computer.wake.ensure_awake", lambda did, **kw: (True, ""))
    monkeypatch.setattr("agent.computer.decide.pick_decision_ref", lambda pref: pref)
    monkeypatch.setattr("tools.vision_tools._model_sees_images", lambda: False)
    ran = []

    def run(goal, steps, cfg, **kw):
        ran.append(kw["device"])
        if kw["device"] == "mac":
            return L.Result("error", reason="Command '['open', '-a', 'Battle.net']' returned non-zero exit status 1.")
        return L.Result("done", device_name="pranav-computer")
    monkeypatch.setattr(L, "run", run)
    out = json.loads(T.handle_computer_do({"goal": "launch Battle.net"}, task_id="t1"))
    assert ran == ["mac", "pc"] and out["ok"] is True



def test_the_computer_is_unlocked_after_waking_before_the_loop(monkeypatch):
    from tools import computer_do_tool as T
    order = []
    monkeypatch.setattr("agent.computer.mac.find_mac", lambda task_id=None, prefer="": ("pc", "pranav-computer", None))
    monkeypatch.setattr("agent.computer.wake.ensure_awake", lambda did, **kw: order.append("awake") or (True, ""))
    monkeypatch.setattr("agent.computer.wake.ensure_unlocked", lambda did, **kw: order.append("unlocked") or (True, ""))
    monkeypatch.setattr("agent.computer.decide.pick_decision_ref", lambda pref: pref)
    monkeypatch.setattr("tools.vision_tools._model_sees_images", lambda: False)
    monkeypatch.setattr(L, "run", lambda goal, steps, cfg, **kw: order.append("loop") or L.Result("done"))
    T.handle_computer_do({"goal": "launch Warzone", "computer": "PC"}, task_id="t1")
    assert order == ["awake", "unlocked", "loop"]
