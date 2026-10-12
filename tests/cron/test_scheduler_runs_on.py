"""The scheduler runs a job on its model, through its harness, or on Default."""
import json
from unittest.mock import MagicMock, patch

import pytest

import cron.scheduler as sched

BIG, FAST = "@anthropic-api:claude-sonnet-5-5", "@ollama-cloud:gemma4:31b"


class FakeAgent:
    built = []

    def __init__(self, **kw):
        self.kw = kw
        self.allowed_tool_names = None
        self._turn_user_context = ""
        self.seen = None
        FakeAgent.built.append(self)

    # Set by a test: the answer agent calls the hand-off tool with this summary.
    handoff_summary = None

    def run_conversation(self, user_message, system_message=None, conversation_history=None,
                         task_id=None, **_):
        self.seen = {"message": user_message, "history": conversation_history,
                     "context": self._turn_user_context, "allowed": self.allowed_tool_names,
                     "wired": getattr(self, "_handoff_wired", None), "task_id": task_id}
        if FakeAgent.handoff_summary and len(FakeAgent.built) == 1:
            from agent import escalation
            from agent.tool_policy import block_message
            self.seen["blocked"] = block_message(self, "handoff", {})
            self.seen["handoff"] = json.loads(escalation.handle_escalate(
                {"summary": FakeAgent.handoff_summary}, task_id=task_id))
        return {"final_response": f"reply from {self.kw['model']}", "completed": True,
                "messages": [{"role": "assistant", "tool_calls": [{"id": "1"}]}]}

    def get_activity_summary(self):
        return {"seconds_since_activity": 0}

    def interrupt(self, *_):
        pass

    def close(self):
        pass


@pytest.fixture()
def env(tmp_path, monkeypatch):
    FakeAgent.built = []
    FakeAgent.handoff_summary = None
    monkeypatch.setattr("agent.harness.refs.claude_cli_installed", lambda: False)
    (tmp_path / "config.yaml").write_text("model:\n  provider: anthropic-api\n  default: claude-haiku-5-5\n")
    monkeypatch.setenv("HERMES_WEBUI_STATE_DIR", str(tmp_path / "webui"))
    monkeypatch.setattr("agent.tool_policy.node_tool_policy",
                        lambda s: (frozenset({"web_search"}), "Use only these tool groups this turn: web.")
                        if s == ["web"] else (None, ""))
    calls = []

    def _resolve(**kwargs):
        calls.append(kwargs.get("requested"))
        return {"api_key": "k", "base_url": "https://x.test", "provider": kwargs.get("requested") or "anthropic-api",
                "api_mode": "chat_completions"}

    patches = [
        patch("cron.scheduler._hermes_home", tmp_path),
        patch("cron.scheduler._get_hermes_home", return_value=tmp_path),
        patch("cron.scheduler._resolve_origin", return_value=None),
        patch("dotenv.load_dotenv"),
        patch("jarviscopilot_state.SessionDB", return_value=MagicMock()),
        patch("jarviscopilot_cli.runtime_provider.resolve_runtime_provider", side_effect=_resolve),
        patch("run_agent.AIAgent", FakeAgent),
        patch("tools.mcp_tool.discover_mcp_tools", return_value=[]),
    ]
    for p in patches:
        p.start()
    yield {"home": tmp_path, "requested": calls}
    for p in patches:
        p.stop()


def _save_harness(home, doc):
    designs = home / "webui" / "harnesses" / "default" / "designs"
    designs.mkdir(parents=True, exist_ok=True)
    (designs / f"{doc['id']}.json").write_text(json.dumps(doc))


def _mail_harness():
    return {
        "id": "mail", "name": "Mail triage",
        "nodes": [
            {"id": "in", "type": "message"},
            {"id": "route", "type": "route", "by": "rules", "labels": ["deep"],
             "rules": [{"match": "keywords", "value": "invoice", "label": "deep"}]},
            {"id": "fast", "type": "answer", "model": FAST, "tools": "lean"},
            {"id": "big", "type": "answer", "model": BIG, "tools": ["web"], "max_steps": 7,
             "instructions": "Be thorough."},
            {"id": "check", "type": "review", "model": FAST, "deliver": "post_if_changed"},
            {"id": "more", "type": "background", "model": FAST, "tools": "all",
             "instructions": "Dig deeper.", "deliver": "post"},
        ],
        "edges": [
            {"from": "in", "to": "route", "when": "always"},
            {"from": "route", "to": "big", "when": "label:deep"},
            {"from": "route", "to": "fast", "when": "default"},
            {"from": "big", "to": "check", "when": "always"},
            {"from": "big", "to": "more", "when": "always"},
        ],
    }


def test_model_job_builds_the_agent_on_its_model(env):
    job = {"id": "m", "name": "m", "prompt": "hi", "model": "gemma4:31b", "provider": "ollama-cloud"}
    success, _out, final, error = sched.run_job(job)
    assert success, error
    assert FakeAgent.built[0].kw["model"] == "gemma4:31b" and env["requested"] == ["ollama-cloud"]
    assert final == "reply from gemma4:31b"


def test_legacy_qualified_model_is_split(env):
    job = {"id": "m", "name": "m", "prompt": "hi", "model": "@ollama-cloud:gemma4:31b"}
    sched.run_job(job)
    assert FakeAgent.built[0].kw["model"] == "gemma4:31b" and env["requested"] == ["ollama-cloud"]


def test_default_job_uses_the_server_default(env):
    sched.run_job({"id": "d", "name": "d", "prompt": "hi"})
    assert FakeAgent.built[0].kw["model"] == "claude-haiku-5-5" and env["requested"] == [None]


def test_harness_job_routes_runs_the_answer_node_then_after_nodes(env, monkeypatch):
    _save_harness(env["home"], _mail_harness())
    reviewed = []

    def fake_one_shot(model_ref, prompt, max_tokens=8, reasoning_off=False, **_):
        reviewed.append((model_ref, prompt))
        return '{"verdict": "fix", "text": "Corrected answer"}'

    monkeypatch.setattr("agent.harness.llm.one_shot_completion", fake_one_shot)
    job = {"id": "h", "name": "mail", "prompt": "Any invoice today?", "harness_id": "mail"}
    success, output, final, error = sched.run_job(job)
    assert success, error

    answer, background = FakeAgent.built
    assert answer.kw["model"] == "claude-sonnet-5-5" and env["requested"][0] == "anthropic-api"
    assert answer.kw["max_iterations"] == 7
    assert answer.seen["allowed"] == frozenset({"web_search"})
    assert "Be thorough." in answer.seen["context"] and "tool groups" in answer.seen["context"]
    assert final == "reply from claude-sonnet-5-5"

    assert reviewed and reviewed[0][0] == FAST and "Any invoice today?" in reviewed[0][1]
    assert background.kw["model"] == "gemma4:31b" and background.seen["allowed"] is None
    history = background.seen["history"]
    assert "Any invoice today?" in history[0]["content"] and history[1]["content"] == final
    assert "Dig deeper." in background.seen["context"]

    # Delivered after the answer, in wire order.
    assert job["_after_deliveries"] == ["Corrected answer", "reply from gemma4:31b"]
    assert "Mail triage" in output and "big" in output


def test_missing_harness_falls_back_to_default(env):
    job = {"id": "x", "name": "x", "prompt": "hi", "harness_id": "gone"}
    success, output, final, error = sched.run_job(job)
    assert success, error
    assert [a.kw["model"] for a in FakeAgent.built] == ["claude-haiku-5-5"]
    assert "gone" in output and "Default" in output
    assert not job.get("_after_deliveries")


def test_deliver_after_results_in_order_skipping_silent(monkeypatch):
    sent = []
    monkeypatch.setattr(sched, "_deliver_result",
                        lambda job, content, adapters=None, loop=None: sent.append(content) or
                        ("boom" if content == "two" else None))
    job = {"id": "j", "_after_deliveries": ["one", "[SILENT]", "two", "three"]}
    assert sched.deliver_after_results(job) == "boom"
    assert sent == ["one", "two", "three"] and "_after_deliveries" not in job


def test_tick_delivers_the_answer_then_after_results():
    sent = []

    def fake_run_job(job):
        job["_after_deliveries"] = ["review fix"]
        return True, "# out", "the answer", None

    with patch("cron.scheduler.get_due_jobs", return_value=[{"id": "t", "name": "t", "deliver": "local"}]), \
         patch("cron.scheduler.advance_next_run"), \
         patch("cron.scheduler.run_job", side_effect=fake_run_job), \
         patch("cron.scheduler.save_job_output", return_value="/tmp/out.md"), \
         patch("cron.scheduler._deliver_result",
               side_effect=lambda job, content, adapters=None, loop=None: sent.append(content)), \
         patch("cron.scheduler.mark_job_run"):
        sched.tick(verbose=False)
    assert sent == ["the answer", "review fix"]


def _fast_claude():
    return {
        "id": "fc", "name": "Fast + Claude",
        "nodes": [
            {"id": "in", "type": "message"},
            {"id": "fast", "type": "answer", "model": FAST, "tools": ["web"]},
            {"id": "claude", "type": "background", "model": BIG, "tools": "all",
             "instructions": "Do the whole job.", "deliver": "speak_or_notify"},
        ],
        "edges": [{"from": "in", "to": "fast", "when": "always"},
                  {"from": "fast", "to": "claude", "when": "handoff"}],
    }


def test_a_hand_off_runs_the_wired_node_and_delivers_its_result(env):
    from agent import escalation
    _save_harness(env["home"], _fast_claude())
    FakeAgent.handoff_summary = "Summarise every unread email in depth"
    job = {"id": "ho", "name": "mail", "prompt": "Check my email", "harness_id": "fc"}
    success, output, final, error = sched.run_job(job)
    assert success, error

    answer, claude = FakeAgent.built
    assert answer.seen["wired"] is True and answer.seen["blocked"] is None
    assert answer.seen["handoff"]["escalated"] is True
    assert "handoff" in answer.seen["context"]                 # the node is told it may hand off
    assert claude.kw["model"] == "claude-sonnet-5-5" and claude.seen["allowed"] is None
    assert "Summarise every unread email in depth" in claude.seen["message"]
    assert "Do the whole job." in claude.seen["context"]
    assert job["_after_deliveries"] == ["reply from claude-sonnet-5-5"]
    assert final == "reply from gemma4:31b"
    assert escalation.get_turn_context(answer.seen["task_id"]) is None   # unbound afterwards


def test_no_hand_off_means_nothing_else_runs(env):
    from agent import escalation
    _save_harness(env["home"], _fast_claude())
    job = {"id": "nh", "name": "mail", "prompt": "Check my email", "harness_id": "fc"}
    success, _out, _final, error = sched.run_job(job)
    assert success, error
    assert len(FakeAgent.built) == 1 and not job.get("_after_deliveries")
    assert escalation.get_turn_context(FakeAgent.built[0].seen["task_id"]) is None


def test_routes_on_the_job_instruction_not_the_assembled_prompt(env):
    doc = _mail_harness()
    # A word only the scheduler's own hint ("report your findings") contains.
    doc["nodes"][1]["rules"] = [{"match": "keywords", "value": "findings", "label": "deep"}]
    _save_harness(env["home"], doc)
    job = {"id": "r", "name": "r", "prompt": "Anything new?", "harness_id": "mail"}
    sched.run_job(job)
    answer = FakeAgent.built[0]
    assert answer.kw["model"] == "gemma4:31b"                   # the default wire, not "deep"
    assert "findings" in answer.seen["message"]                 # the agent still gets the full prompt


def test_anthropic_picks_run_on_claude_code_like_chat(env, monkeypatch):
    monkeypatch.setattr("agent.harness.refs.claude_cli_installed", lambda: True)
    sched.run_job({"id": "a", "name": "a", "prompt": "hi", "model": "@anthropic:claude-sonnet-5-5"})
    sched.run_job({"id": "b", "name": "b", "prompt": "hi", "model": "@anthropic-api:claude-haiku-5-5"})
    assert env["requested"] == ["claude-code", "anthropic-api"]


def test_default_on_an_anthropic_config_runs_on_claude_code(env, monkeypatch):
    (env["home"] / "config.yaml").write_text("model:\n  provider: anthropic\n  default: claude-sonnet-5-5\n")
    monkeypatch.setattr("agent.harness.refs.claude_cli_installed", lambda: True)
    sched.run_job({"id": "d", "name": "d", "prompt": "hi"})
    assert env["requested"] == ["claude-code"]
