import copy
from types import SimpleNamespace

from api.harness_builtins import builtin_harnesses
from api.harness_runner import (RouteDecision, _parse_label, _route_choices, _route_prompt,
                                classify_with_model, plan_turn, resolve_harness, single_harness)
from api.harness_store import HarnessStore

FAST, CLAUDE = "@ollama-cloud:gemma4:31b", "@claude-code:claude-sonnet-5-5"


def _bi(hid):
    return next(b for b in builtin_harnesses(FAST, CLAUDE) if b["id"] == hid)


def _sess(harness_id=None):
    return SimpleNamespace(harness_id=harness_id, model="gpt-x", model_provider="openai-codex")


def test_turn_without_harness_id_runs_single_with_explicit_model(tmp_path):
    doc, note = resolve_harness(HarnessStore(tmp_path), session=_sess("router"), surface="chat",
                                requested_id=None, explicit_model=("@anthropic:claude-sonnet-5-5", "anthropic"))
    plan = plan_turn(doc, session_model="@anthropic:claude-sonnet-5-5", session_provider="anthropic",
                     text="fix my code", surface="chat", has_attachments=False)
    assert plan.harness_id == "single" and plan.model == "@anthropic:claude-sonnet-5-5"
    assert plan.cache_key("s1") == "s1"


def test_requested_then_session_then_surface_default(tmp_path):
    st = HarnessStore(tmp_path)
    assert resolve_harness(st, session=_sess("router"), surface="chat",
                           requested_id="fast-checked", explicit_model=None)[0]["id"] == "fast-checked"
    assert resolve_harness(st, session=_sess("router"), surface="chat",
                           requested_id=None, explicit_model=None)[0]["id"] == "router"
    assert resolve_harness(st, session=_sess(), surface="voice",
                           requested_id=None, explicit_model=None)[0]["id"] == "fast-claude"


def test_invalid_stored_harness_falls_back_to_single(tmp_path):
    st = HarnessStore(tmp_path)
    st._designs_dir.mkdir(parents=True)
    (st._designs_dir / "broken.json").write_text('{"id": "broken", "nodes": [], "edges": []}')
    doc, note = resolve_harness(st, session=_sess("broken"), surface="chat", requested_id=None, explicit_model=None)
    assert doc["id"] == "single" and "broken" in note


def test_unknown_harness_falls_back_to_single(tmp_path):
    doc, note = resolve_harness(HarnessStore(tmp_path), session=_sess(), surface="chat",
                                requested_id="nope", explicit_model=None)
    assert doc["id"] == "single" and "nope" in note


def test_fast_claude_plans_fast_node_with_handoff():
    plan = plan_turn(_bi("fast-claude"), session_model="m", session_provider=None,
                     text="what time is it", surface="voice", has_attachments=False)
    assert plan.node_id == "fast" and plan.model == FAST and plan.provider == "ollama-cloud"
    assert plan.handoff_node["id"] == "claude" and plan.cache_key("s1") == "s1#fast-claude:fast"
    assert plan.meta()["node"] == "fast" and plan.meta()["kind"] == "answer"


def test_router_rules():
    r = _bi("router")
    kw = dict(session_model="m", session_provider=None, surface="chat")
    assert plan_turn(r, text="fix this bug in my code", has_attachments=False, **kw).node_id == "claude"
    assert plan_turn(r, text="hi there", has_attachments=False, **kw).node_id == "fast"
    assert plan_turn(r, text="look", has_attachments=True, **kw).node_id == "claude"


def test_model_route_uses_classifier_and_defaults_on_none():
    doc = copy.deepcopy(_bi("router"))
    doc["nodes"][1].update({"by": "model", "model": FAST, "rules": [], "labels": ["deep"]})
    kw = dict(session_model="m", session_provider=None, text="x", surface="chat", has_attachments=False)
    plan = plan_turn(doc, classify=lambda node, text: RouteDecision("deep", "model", FAST, None, 120), **kw)
    assert plan.node_id == "claude"
    assert plan.meta()["route"] == {"node": doc["nodes"][1]["id"], "label": "deep", "by": "model",
                                    "model": FAST, "confidence": None, "ms": 120, "error": None}
    plan = plan_turn(doc, classify=lambda node, text: RouteDecision(None, "model", FAST), **kw)
    assert plan.node_id == "fast" and plan.meta()["route"]["label"] == "default"


def test_rules_route_recorded_in_meta():
    plan = plan_turn(_bi("router"), session_model="m", session_provider=None,
                     text="fix this bug in my code", surface="chat", has_attachments=False)
    assert plan.meta()["route"]["by"] == "rules" and plan.meta()["route"]["label"] != "default"


def test_single_harness_has_no_route_meta():
    plan = plan_turn(single_harness(), session_model="@x:y", session_provider="x",
                     text="hi", surface="chat", has_attachments=False)
    assert "route" not in plan.meta()


def test_decision_route_uses_the_decision_client(monkeypatch):
    from agent import decision_client
    seen = {}

    def fake_choose(provider, model, *, instructions, choices, text, timeout, client=None):
        seen.update(provider=provider, model=model, instructions=instructions, choices=choices, text=text)
        return decision_client.Decision(choice="deep", confidence=0.82, ms=71)

    monkeypatch.setattr(decision_client, "choose", fake_choose)
    node = {"id": "r", "model": "@celeris:celeris-1-decision", "labels": ["deep", "quick"],
            "label_descriptions": {"deep": "needs research"}, "instructions": "Pick a lane."}
    d = classify_with_model(node, "debug my code")
    assert (d.label, d.by, d.confidence, d.error) == ("deep", "decision", 0.82, None)
    assert seen["provider"] == "celeris" and seen["model"] == "celeris-1-decision"
    assert seen["instructions"] == "Pick a lane." and seen["text"] == "debug my code"
    assert seen["choices"] == [("deep", "needs research"), ("quick", None),
                               ("none", "None of the other routes fit.")]


def test_decision_none_takes_default(monkeypatch):
    from agent import decision_client
    monkeypatch.setattr(decision_client, "choose",
                        lambda *a, **k: decision_client.Decision(choice="none", confidence=0.6))
    d = classify_with_model({"id": "r", "model": "@celeris:celeris-1-decision", "labels": ["deep"]}, "hi")
    assert d.label is None and d.error is None and d.by == "decision"


def test_decision_route_failure_takes_default_with_error(monkeypatch):
    from agent import decision_client

    def boom(*a, **k):
        raise decision_client.DecisionError("HTTP 402: out of credits")

    monkeypatch.setattr(decision_client, "choose", boom)
    d = classify_with_model({"id": "r", "model": "@celeris:celeris-1-decision", "labels": ["deep"]}, "hi")
    assert d.label is None and d.error == "HTTP 402: out of credits"


def test_decision_choices_skip_none_when_label_is_none():
    assert [v for v, _ in _route_choices({"labels": ["deep", "none"]})] == ["deep", "none"]


def test_chat_route_prompt_carries_instructions_and_descriptions():
    p = _route_prompt({"labels": ["deep", "quick"], "label_descriptions": {"deep": "needs research"},
                       "instructions": "Pick a lane."}, "debug my code")
    assert "Pick a lane." in p and "- deep: needs research" in p and "- quick" in p and "- none" in p
    assert p.rstrip().endswith("debug my code")


def test_chat_route_parse_lenient_and_none():
    labels = ["deep", "code review"]
    assert _parse_label("Deep.", labels) == "deep"
    assert _parse_label("**code review**", labels) == "code review"
    assert _parse_label("I'd say deep", labels) == "deep"
    assert _parse_label("none", labels) is None
    assert _parse_label("none of these, maybe deep", labels) is None
    assert _parse_label("banana", labels) is None


def test_chat_route_turns_reasoning_off(monkeypatch):
    import api.harness_llm as llm
    seen = {}

    def fake(model_ref, prompt, max_tokens=8, reasoning_off=False):
        seen.update(ref=model_ref, reasoning_off=reasoning_off)
        return "deep"

    monkeypatch.setattr(llm, "one_shot_completion", fake)
    d = classify_with_model({"id": "r", "model": "@celeris:celeris-1-magnus", "labels": ["deep"]}, "x")
    assert d.label == "deep" and d.by == "model" and seen["reasoning_off"] is True


def test_review_edge_lands_in_after_list():
    plan = plan_turn(_bi("fast-checked"), session_model="m", session_provider=None,
                     text="hi", surface="chat", has_attachments=False)
    assert [(n["id"], w) for n, w in plan.after] == [("check", "always")]


def test_single_uses_session_model():
    plan = plan_turn(single_harness(), session_model="@x:y", session_provider="x",
                     text="hi", surface="chat", has_attachments=False)
    assert (plan.model, plan.provider) == ("@x:y", "x")


def test_classifier_failure_returns_default_fast():
    d = classify_with_model({"id": "r", "model": "@nope:nope", "labels": ["a"]}, "x", timeout=0.2)
    assert d.label is None and d.error


def test_route_choices_are_unique():
    assert [v for v, _ in _route_choices({"labels": ["deep", "deep", "quick"]})] == ["deep", "quick", "none"]


def test_decision_route_without_real_labels_makes_no_call(monkeypatch):
    from agent import decision_client

    def must_not_call(*a, **k):
        raise AssertionError("called")

    monkeypatch.setattr(decision_client, "choose", must_not_call)
    for labels in ([], ["None"]):
        d = classify_with_model({"id": "r", "model": "@celeris:celeris-1-decision", "labels": labels}, "hi")
        assert d.label is None and d.error == "no labels to pick from"


def test_chat_route_parse_prefers_the_longest_label():
    assert _parse_label("I'd pick deep research", ["deep", "deep research"]) == "deep research"


def test_a_saved_design_the_newer_checks_flag_still_runs(tmp_path):
    """A label with no wire (or a wire whose label isn't one) is refused when
    saving, but a design saved before those checks must keep routing, not drop
    to Single every turn."""
    import json
    st = HarnessStore(tmp_path)
    st._designs_dir.mkdir(parents=True)
    doc = {"id": "older", "name": "Older", "nodes": [
        {"id": "in", "type": "message"},
        {"id": "r", "type": "route", "by": "model", "model": "@celeris:celeris-1-decision",
         "labels": ["deep", "path-2"]},
        {"id": "a", "type": "answer", "model": "@x:y"}, {"id": "b", "type": "answer", "model": "@x:z"},
        {"id": "c", "type": "answer", "model": "@x:w"}],
        "edges": [{"from": "in", "to": "r"}, {"from": "r", "to": "a", "when": "label:deep"},
                  {"from": "r", "to": "b", "when": "default"}, {"from": "r", "to": "c", "when": "label:long-running"}]}
    (st._designs_dir / "older.json").write_text(json.dumps(doc))
    got, note = resolve_harness(st, session=_sess("older"), surface="chat", requested_id=None, explicit_model=None)
    assert got["id"] == "older" and note is None
    from api.harness_schema import validate_harness
    assert validate_harness(doc)[1]          # still refused when saving
