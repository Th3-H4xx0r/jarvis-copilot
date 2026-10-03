import copy
from types import SimpleNamespace

from api.harness_builtins import builtin_harnesses
from api.harness_runner import classify_with_model, plan_turn, resolve_harness, single_harness
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
    assert plan_turn(doc, classify=lambda ref, labels, text: "deep", **kw).node_id == "claude"
    assert plan_turn(doc, classify=lambda *a: None, **kw).node_id == "fast"


def test_review_edge_lands_in_after_list():
    plan = plan_turn(_bi("fast-checked"), session_model="m", session_provider=None,
                     text="hi", surface="chat", has_attachments=False)
    assert [(n["id"], w) for n, w in plan.after] == [("check", "always")]


def test_single_uses_session_model():
    plan = plan_turn(single_harness(), session_model="@x:y", session_provider="x",
                     text="hi", surface="chat", has_attachments=False)
    assert (plan.model, plan.provider) == ("@x:y", "x")


def test_classifier_failure_returns_none_fast():
    assert classify_with_model("@nope:nope", ["a"], "x", timeout=0.2) is None
