"""The Computer node: a decision model drives the Mac; hands and stuck wires."""
import pytest

from agent.harness import refs
from agent.harness import schema
from agent.harness.planner import plan_turn
from agent.harness.schema import validate_harness

DEC, HAIKU, SONNET = "@celeris:celeris-1-decision", "@anthropic-api:claude-haiku-5-5", "@anthropic-api:claude-sonnet-5-5"


@pytest.fixture(autouse=True)
def _decision_refs(monkeypatch):
    refs.register_splitter(None)
    monkeypatch.setattr(schema, "_is_decision_ref", lambda ref: ref == DEC)
    yield
    refs.register_splitter(None)


def _doc(**node_overrides):
    mac = {"id": "mac", "type": "computer", "label": "Mac", "model": DEC, "fallback_model": HAIKU,
           "max_steps": 20, "instructions": "Use keyboard shortcuts.", **node_overrides}
    return {"id": "h", "name": "H", "nodes": [
        {"id": "in", "type": "message"},
        {"id": "route", "type": "route", "by": "rules", "labels": ["computer"],
         "rules": [{"match": "keywords", "value": "mac", "label": "computer"}]},
        mac,
        {"id": "big", "type": "answer", "model": SONNET, "tools": "all"},
        {"id": "fast", "type": "answer", "model": HAIKU, "tools": "lean"},
    ], "edges": [
        {"from": "in", "to": "route", "when": "always"},
        {"from": "route", "to": "mac", "when": "label:computer"},
        {"from": "route", "to": "fast", "when": "default"},
        {"from": "mac", "to": "big", "when": "stuck"},
        {"from": "big", "to": "mac", "when": "hands"},
    ]}


def _errors(doc):
    return [e["message"] for e in validate_harness(doc)[1]]


def test_hands_and_stuck_wires_not_a_loop():
    clean, errors = validate_harness(_doc())
    assert errors == []
    mac = next(n for n in clean["nodes"] if n["id"] == "mac")
    assert mac == {"id": "mac", "type": "computer", "x": 0.0, "y": 0.0, "label": "Mac", "model": DEC,
                   "fallback_model": HAIKU, "max_steps": 20, "instructions": "Use keyboard shortcuts."}
    assert {"from": "mac", "to": "big", "when": "stuck"} in clean["edges"]


def test_model_fields_checked():
    assert any("decision model" in m for m in _errors(_doc(model=HAIKU)))
    assert any("decision model" in m for m in _errors(_doc(fallback_model=DEC)))
    assert _errors(_doc(model="", fallback_model="")) == []


def test_stuck_and_hands_shapes():
    doc = _doc()
    doc["edges"].append({"from": "fast", "to": "big", "when": "stuck"})
    assert any("stuck wire" in m for m in _errors(doc))
    doc = _doc()
    doc["edges"].append({"from": "big", "to": "fast", "when": "hands"})
    assert any("hands wire" in m for m in _errors(doc))


def test_flow_reached_computer_needs_one_stuck_wire():
    doc = _doc()
    doc["edges"] = [e for e in doc["edges"] if e["when"] != "stuck"]
    assert any("stuck" in m for m in _errors(doc))
    doc = _doc()
    doc["edges"].append({"from": "mac", "to": "fast", "when": "stuck"})
    assert any("one stuck wire" in m for m in _errors(doc))


def test_computer_reached_only_by_hands_is_connected():
    doc = _doc()
    doc["edges"] = [{"from": "in", "to": "route", "when": "always"},
                    {"from": "route", "to": "big", "when": "label:computer"},
                    {"from": "route", "to": "fast", "when": "default"},
                    {"from": "big", "to": "mac", "when": "hands"}]
    assert _errors(doc) == []


def test_plan_route_to_computer_runs_it_first():
    clean = validate_harness(_doc())[0]
    plan = plan_turn(clean, session_model="m", session_provider="p", text="on my mac open calculator",
                     surface="chat", has_attachments=False)
    assert plan.computer_first is True and plan.computer["id"] == "mac"
    assert (plan.node_id, plan.model) == ("big", SONNET)


def test_plan_hands_binds_without_running_first():
    doc = _doc()
    doc["edges"].append({"from": "fast", "to": "mac", "when": "hands"})
    clean = validate_harness(doc)[0]
    plan = plan_turn(clean, session_model="m", session_provider="p", text="hello",
                     surface="chat", has_attachments=False)
    assert plan.node_id == "fast" and plan.computer["id"] == "mac" and plan.computer_first is False


def test_plan_without_computer():
    clean = validate_harness(_doc())[0]
    plan = plan_turn(clean, session_model="m", session_provider="p", text="hello",
                     surface="chat", has_attachments=False)
    assert plan.node_id == "fast" and plan.computer is None and plan.computer_first is False
