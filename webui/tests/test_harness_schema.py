import copy

import pytest

from api.harness_schema import parse_when, validate_harness

GOOD = {
    "id": "fast-claude", "name": "Fast + Claude", "icon": "⚡",
    "nodes": [
        {"id": "in", "type": "message", "x": 0, "y": 0},
        {"id": "fast", "type": "answer", "model": "@ollama-cloud:gemma4:31b", "tools": "lean"},
        {"id": "claude", "type": "background", "model": "@claude-code:claude-sonnet-5-5",
         "tools": "all", "deliver": "speak_or_notify"},
    ],
    "edges": [{"from": "in", "to": "fast"}, {"from": "fast", "to": "claude", "when": "handoff"}],
}


def _errs(doc):
    return [e["message"] for e in validate_harness(doc)[1]]


def test_good_doc_validates():
    doc, errors = validate_harness(copy.deepcopy(GOOD))
    assert errors == [] and doc["id"] == "fast-claude" and doc["edges"][0]["when"] == "always"


@pytest.mark.parametrize("when,expected", [
    ("always", ("always", None)), ("handoff", ("handoff", None)), ("default", ("default", None)),
    ("label:coding", ("label", "coding")), ("slow:20", ("slow", "20")), ("tools:5", ("tools", "5")),
])
def test_parse_when(when, expected):
    assert parse_when(when) == expected


def test_parse_when_rejects_garbage():
    with pytest.raises(ValueError):
        parse_when("sometimes")


def test_exactly_one_message_node():
    d = copy.deepcopy(GOOD)
    d["nodes"].append({"id": "in2", "type": "message"})
    assert any("one Message" in m for m in _errs(d))


def test_cycle_rejected():
    d = copy.deepcopy(GOOD)
    d["edges"].append({"from": "claude", "to": "fast", "when": "always"})
    assert any("loop" in m for m in _errs(d))


def test_unreachable_node_rejected():
    d = copy.deepcopy(GOOD)
    d["nodes"].append({"id": "orphan", "type": "answer", "model": "@x:y"})
    assert any("not connected" in m for m in _errs(d))


def test_path_needs_a_foreground_answer_before_background():
    d = copy.deepcopy(GOOD)
    d["nodes"] = [n for n in d["nodes"] if n["id"] != "fast"]
    d["edges"] = [{"from": "in", "to": "claude"}]
    assert any("before any Answer" in m for m in _errs(d))


def test_route_needs_default_edge():
    d = copy.deepcopy(GOOD)
    d["nodes"].insert(1, {"id": "r", "type": "route", "by": "rules",
                          "rules": [{"match": "keywords", "value": "code", "label": "coding"}]})
    d["edges"] = [{"from": "in", "to": "r"}, {"from": "r", "to": "fast", "when": "label:coding"},
                  {"from": "fast", "to": "claude", "when": "handoff"}]
    assert any("default" in m for m in _errs(d))


def test_handoff_only_from_answer_to_background():
    d = copy.deepcopy(GOOD)
    d["nodes"][2]["type"] = "review"
    d["nodes"][2]["deliver"] = "post"
    assert any("hand-off" in m for m in _errs(d))


def test_answer_needs_model_and_known_tools():
    d = copy.deepcopy(GOOD)
    d["nodes"][1]["model"] = ""
    d["nodes"][1]["tools"] = "everything"
    msgs = _errs(d)
    assert any("model" in m for m in msgs) and any("tools" in m for m in msgs)


def test_ids_are_safe():
    d = copy.deepcopy(GOOD)
    d["id"] = "../etc"
    assert any("id" in m for m in _errs(d))


def test_two_foreground_answers_on_one_path_rejected():
    d = copy.deepcopy(GOOD)
    d["nodes"].append({"id": "second", "type": "answer", "model": "@x:y"})
    d["edges"].append({"from": "fast", "to": "second", "when": "always"})
    assert any("Only one Answer" in m for m in _errs(d))


def test_not_an_object():
    assert validate_harness(None)[0] is None and validate_harness(None)[1]
