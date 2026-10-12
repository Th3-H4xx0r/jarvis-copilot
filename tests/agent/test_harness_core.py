"""The core harness package: planning and store reading without the web UI."""
import json

import pytest

from agent.harness import refs
from agent.harness.planner import RouteDecision, after_condition_holds, plan_turn, review_result
from agent.harness.schema import validate_harness
from agent.harness.store import HarnessStore, store_for_home

FAST, BIG = "@ollama-cloud:gemma4:31b", "@anthropic-api:claude-sonnet-5-5"


def _route_doc(hid="mail"):
    return {
        "id": hid, "name": "Mail triage",
        "nodes": [
            {"id": "in", "type": "message"},
            {"id": "route", "type": "route", "by": "rules", "labels": ["deep"],
             "rules": [{"match": "keywords", "value": "invoice, contract", "label": "deep"}]},
            {"id": "fast", "type": "answer", "model": FAST, "tools": "lean"},
            {"id": "big", "type": "answer", "model": BIG, "tools": ["web"], "max_steps": 7,
             "instructions": "Be thorough."},
            {"id": "check", "type": "review", "model": FAST, "deliver": "post_if_changed"},
        ],
        "edges": [
            {"from": "in", "to": "route", "when": "always"},
            {"from": "route", "to": "big", "when": "label:deep"},
            {"from": "route", "to": "fast", "when": "default"},
            {"from": "big", "to": "check", "when": "always"},
        ],
    }


@pytest.fixture(autouse=True)
def _no_registered_splitter():
    refs.register_splitter(None)
    yield
    refs.register_splitter(None)


def test_route_then_answer_with_after_nodes():
    doc, errors = validate_harness(_route_doc())
    assert not errors
    plan = plan_turn(doc, session_model="m", session_provider=None, text="Check this invoice",
                     surface="schedule", has_attachments=False)
    assert (plan.node_id, plan.model, plan.provider) == ("big", BIG, "anthropic-api")
    assert plan.tools == ["web"] and plan.max_steps == 7 and plan.instructions == "Be thorough."
    assert [(n["id"], w) for n, w in plan.after] == [("check", "always")]
    assert plan.route["label"] == "deep" and plan.surface == "schedule"
    other = plan_turn(doc, session_model="m", session_provider=None, text="hello",
                      surface="schedule", has_attachments=False)
    assert other.node_id == "fast" and other.after == []


def test_model_route_takes_injected_classifier():
    doc = _route_doc()
    doc["nodes"][1].update({"by": "model", "model": FAST, "rules": []})
    plan = plan_turn(doc, session_model="m", session_provider=None, text="x", surface="schedule",
                     has_attachments=False, classify=lambda node, text: RouteDecision("deep", "model", FAST))
    assert plan.node_id == "big"


def test_store_reads_designs_from_the_home_webui_state_dir(tmp_path, monkeypatch):
    home = tmp_path / "root"
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.delenv("HERMES_WEBUI_STATE_DIR", raising=False)
    designs = home / "webui" / "harnesses" / "default" / "designs"
    designs.mkdir(parents=True)
    (designs / "mail.json").write_text(json.dumps(_route_doc()))
    st = store_for_home()
    assert st.get("mail")["name"] == "Mail triage"
    assert st.find("mail triage")["id"] == "mail"
    assert st.get("single") is not None        # built-ins merge in on read
    assert st.get("../etc") is None and st.get("nope") is None


def test_store_owner_is_the_profile_of_the_home(tmp_path, monkeypatch):
    root = tmp_path / "root"
    monkeypatch.setenv("HERMES_HOME", str(root / "profiles" / "work"))
    monkeypatch.delenv("HERMES_WEBUI_STATE_DIR", raising=False)
    designs = root / "webui" / "harnesses" / "work" / "designs"
    designs.mkdir(parents=True)
    (designs / "mail.json").write_text(json.dumps(_route_doc()))
    assert store_for_home().get("mail") is not None


def test_state_dir_env_wins(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_WEBUI_STATE_DIR", str(tmp_path / "state"))
    st = store_for_home()
    assert st.base.parent.parent == tmp_path / "state"
    assert HarnessStore(tmp_path).get_assignments()["chat"] == "single"


def test_default_split_keeps_tags_and_custom_slugs():
    assert refs.split_ref(FAST) == ("ollama-cloud", "gemma4:31b")
    assert refs.split_ref("@custom:my-box:llama3:8b") == ("custom:my-box", "llama3:8b")
    assert refs.split_ref("@custom:10.0.0.2:8080:llama3") == ("custom:10.0.0.2:8080", "llama3")
    assert refs.split_ref("claude-haiku-5-5") is None and refs.split_ref("") is None


def test_registered_splitter_wins():
    refs.register_splitter(lambda ref: ("x", "y"))
    assert refs.split_ref("@a:b") == ("x", "y")


def test_after_conditions():
    assert after_condition_holds("always", elapsed_s=0, tool_count=0)
    assert not after_condition_holds("slow:30", elapsed_s=10, tool_count=0)
    assert after_condition_holds("slow:30", elapsed_s=31, tool_count=0)
    assert after_condition_holds("tools:2", elapsed_s=0, tool_count=3)
    assert not after_condition_holds("handoff", elapsed_s=99, tool_count=99)


def test_review_result_posts_fix_only_unless_post():
    fix = '{"verdict": "fix", "text": "Better"}'
    ok = '{"verdict": "ok", "text": "Same"}'
    assert review_result({"deliver": "post_if_changed"}, fix) == "Better"
    assert review_result({"deliver": "post_if_changed"}, ok) == ""
    assert review_result({"deliver": "post"}, ok) == "Same"
    assert review_result({"deliver": "post"}, "no json") == ""


def test_schedule_model_route_gets_a_longer_timeout(monkeypatch):
    import agent.harness.planner as planner
    seen = []
    monkeypatch.setattr(planner, "classify_with_model",
                        lambda node, text, timeout=1.5, **kw: seen.append(timeout) or RouteDecision(None, "model", FAST))
    doc = _route_doc()
    doc["nodes"][1].update({"by": "model", "model": FAST, "rules": []})
    kw = dict(session_model="m", session_provider=None, text="x", has_attachments=False)
    planner.plan_turn(doc, surface="schedule", **kw)
    planner.plan_turn(doc, surface="chat", **kw)
    assert seen[0] >= 10 and seen[1] == 1.5


def test_anthropic_picks_run_on_claude_code_when_installed(monkeypatch):
    from agent.harness import llm
    monkeypatch.setattr(refs, "claude_cli_installed", lambda: True)
    assert refs.route_anthropic_via_claude_code("claude-sonnet-5-5", "anthropic", None)[1] == "claude-code"
    assert refs.route_anthropic_via_claude_code("claude-haiku-5-5", "anthropic-api", None)[1] == "anthropic-api"
    assert llm.resolve_ref("@anthropic:claude-sonnet-5-5")[:2] == ("claude-sonnet-5-5", "claude-code")
    assert llm.resolve_ref("@anthropic-api:claude-haiku-5-5")[:2] == ("claude-haiku-5-5", "anthropic-api")
    monkeypatch.setattr(refs, "claude_cli_installed", lambda: False)
    assert refs.route_anthropic_via_claude_code("claude-sonnet-5-5", "anthropic", None)[1] == "anthropic"


def test_claude_cli_detection_honours_the_command_env(monkeypatch):
    import shutil
    monkeypatch.setenv("HERMES_CLAUDE_CODE_COMMAND", "my-claude")
    monkeypatch.setattr(shutil, "which", lambda cmd: "/bin/x" if cmd == "my-claude" else None)
    assert refs.claude_cli_installed() is True
    monkeypatch.setenv("HERMES_CLAUDE_CODE_COMMAND", "nope")
    assert refs.claude_cli_installed() is False
