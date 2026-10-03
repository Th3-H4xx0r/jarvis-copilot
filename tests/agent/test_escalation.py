"""Plan 2.5 — the ``escalate`` tool and its background hand-off to the big model.

The fast lane (Haiku) answers immediately; when a turn is beyond it the model
calls ``escalate(reason, summary)``. That call ends the fast turn with the ack
text it already produced and hands the same turn to the escalation model in a
background job, whose result is pushed back to the session's stream as
``{"type": "escalation_result", "job_id", "text"}``.
"""
from __future__ import annotations

import json
import threading
import time

import pytest

from agent import escalation


@pytest.fixture(autouse=True)
def _clean():
    escalation.reset_for_tests()
    yield
    escalation.reset_for_tests()


def _wait_for(pred, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(0.01)
    return False


# ── config reading ───────────────────────────────────────────────────────────

class TestLaneConfig:
    def test_absent_config_means_no_fast_lane(self):
        assert escalation.fast_lane_config({}, "voice")["enabled"] is False
        assert escalation.fast_lane_config(None, "voice")["enabled"] is False

    def test_bare_boolean(self):
        cfg = escalation.fast_lane_config({"voice": {"fast_lane": True}}, "voice")
        assert cfg["enabled"] is True
        assert cfg["model"] is None

    def test_provider_qualified_string(self):
        cfg = escalation.fast_lane_config(
            {"voice": {"fast_lane": "@anthropic:claude-haiku-4-5"}}, "voice")
        assert cfg == {"enabled": True, "provider": "anthropic",
                       "model": "claude-haiku-4-5"}

    def test_dict_form(self):
        cfg = escalation.fast_lane_config(
            {"voice": {"fast_lane": {"enabled": True, "provider": "anthropic",
                                     "model": "claude-haiku-4-5"}}}, "voice")
        assert cfg == {"enabled": True, "provider": "anthropic",
                       "model": "claude-haiku-4-5"}

    def test_dict_form_with_qualified_model(self):
        cfg = escalation.fast_lane_config(
            {"voice": {"fast_lane": {"model": "@anthropic:claude-haiku-4-5"}}}, "voice")
        assert cfg["enabled"] is True  # a model implies the lane is on
        assert cfg["provider"] == "anthropic"

    def test_explicit_disable_wins_over_model(self):
        cfg = escalation.fast_lane_config(
            {"voice": {"fast_lane": {"enabled": False,
                                     "model": "claude-haiku-4-5"}}}, "voice")
        assert cfg["enabled"] is False

    def test_chat_lane_uses_the_same_shape(self):
        cfg = escalation.fast_lane_config({"chat": {"fast_lane": True}}, "chat")
        assert cfg["enabled"] is True

    def test_escalation_defaults_to_sonnet_5(self):
        cfg = escalation.escalation_config({"voice": {"fast_lane": True}}, "voice")
        assert cfg["enabled"] is True
        assert cfg["model"] == escalation.DEFAULT_ESCALATION_MODEL == "claude-sonnet-5"

    def test_escalation_can_be_turned_off_while_the_fast_lane_stays_on(self):
        cfg = escalation.escalation_config(
            {"voice": {"fast_lane": True, "escalation": {"enabled": False}}}, "voice")
        assert cfg["enabled"] is False

    def test_escalation_model_override(self):
        cfg = escalation.escalation_config(
            {"voice": {"fast_lane": True,
                       "escalation": {"model": "@anthropic:claude-opus-5"}}}, "voice")
        assert cfg["model"] == "claude-opus-5"
        assert cfg["provider"] == "anthropic"

    def test_fast_lane_active_scans_every_lane(self):
        assert escalation.fast_lane_active({"chat": {"fast_lane": True}}) is True
        assert escalation.fast_lane_active({"voice": {"fast_lane": True}}) is True
        assert escalation.fast_lane_active({"voice": {"fast_lane": False}}) is False
        assert escalation.fast_lane_active({}) is False


# ── the tool ─────────────────────────────────────────────────────────────────

class TestEscalateTool:
    def test_schema_shape(self):
        schema = escalation.escalate_tool_schema()
        assert schema["name"] == "escalate"
        props = schema["parameters"]["properties"]
        assert set(props) == {"reason", "summary"}
        assert schema["parameters"]["required"] == ["reason", "summary"]

    def test_registered_only_when_a_fast_lane_is_active(self, monkeypatch):
        from tools.registry import registry, invalidate_check_fn_cache

        monkeypatch.setattr(escalation, "_load_config", lambda: {})
        invalidate_check_fn_cache()
        assert registry.get_definitions({"escalate"}) == []

        monkeypatch.setattr(escalation, "_load_config",
                            lambda: {"voice": {"fast_lane": True}})
        invalidate_check_fn_cache()
        defs = registry.get_definitions({"escalate"})
        assert [d["function"]["name"] for d in defs] == ["escalate"]

    def test_handler_returns_an_ack_and_starts_a_job(self, monkeypatch):
        monkeypatch.setattr(escalation, "_load_config",
                            lambda: {"voice": {"fast_lane": True}})
        done = threading.Event()

        def _runner(job):
            done.set()
            return "the long answer"

        escalation.bind_turn_context("task-1", session_id="sess-1", runner=_runner)
        out = escalation.handle_escalate(
            {"reason": "needs web research", "summary": "find the best CPU"},
            task_id="task-1",
        )
        payload = json.loads(out)
        assert payload["escalated"] is True
        assert payload["job_id"]
        assert done.wait(5)
        assert _wait_for(lambda: escalation.get_job(payload["job_id"])["status"] == "done")
        assert escalation.get_job(payload["job_id"])["text"] == "the long answer"

    def test_handler_without_a_bound_turn_is_a_soft_no_op(self, monkeypatch):
        monkeypatch.setattr(escalation, "_load_config",
                            lambda: {"voice": {"fast_lane": True}})
        out = json.loads(escalation.handle_escalate(
            {"reason": "r", "summary": "s"}, task_id="unbound"))
        assert out["escalated"] is False
        assert "error" in out


# ── background job + delivery ────────────────────────────────────────────────

class TestEscalationJob:
    def test_result_is_delivered_to_a_live_sink(self):
        seen = []
        escalation.register_stream_sink("sess-1", lambda ev, data: seen.append((ev, data)))
        job_id = escalation.start_escalation(
            session_id="sess-1", reason="r", summary="s",
            runner=lambda job: "big model answer",
        )
        assert _wait_for(lambda: seen)
        event, data = seen[0]
        assert event == "escalation_result"
        assert data == {"type": "escalation_result", "job_id": job_id,
                        "text": "big model answer"}

    def test_result_is_buffered_when_no_sink_is_live(self):
        job_id = escalation.start_escalation(
            session_id="sess-2", reason="r", summary="s",
            runner=lambda job: "answer for later",
        )
        assert _wait_for(lambda: escalation.get_job(job_id)["status"] == "done")
        pending = escalation.drain_pending("sess-2")
        assert [p[1]["text"] for p in pending] == ["answer for later"]
        assert escalation.drain_pending("sess-2") == [], "drain must be one-shot"

    def test_pending_events_flush_to_a_sink_registered_later(self):
        escalation.start_escalation(
            session_id="sess-3", reason="r", summary="s",
            runner=lambda job: "late",
        )
        assert _wait_for(lambda: escalation.pending_count("sess-3") == 1)
        seen = []
        escalation.register_stream_sink("sess-3", lambda ev, data: seen.append(data))
        assert [s["text"] for s in seen] == ["late"]
        assert escalation.pending_count("sess-3") == 0

    def test_a_failing_runner_marks_the_job_failed_and_still_reports(self):
        seen = []
        escalation.register_stream_sink("sess-4", lambda ev, data: seen.append(data))

        def _boom(job):
            raise RuntimeError("model exploded")

        job_id = escalation.start_escalation(
            session_id="sess-4", reason="r", summary="s", runner=_boom)
        assert _wait_for(lambda: escalation.get_job(job_id)["status"] == "failed")
        assert seen and seen[0]["job_id"] == job_id
        assert "could not" in seen[0]["text"].lower() or seen[0]["text"]

    def test_a_broken_sink_never_kills_the_job(self):
        def _bad_sink(ev, data):
            raise RuntimeError("sink is gone")

        escalation.register_stream_sink("sess-5", _bad_sink)
        job_id = escalation.start_escalation(
            session_id="sess-5", reason="r", summary="s", runner=lambda job: "x")
        assert _wait_for(lambda: escalation.get_job(job_id)["status"] == "done")

    def test_unregister_stops_delivery(self):
        seen = []

        def _sink(ev, data):
            seen.append(data)

        escalation.register_stream_sink("sess-6", _sink)
        escalation.unregister_stream_sink("sess-6", _sink)
        job_id = escalation.start_escalation(
            session_id="sess-6", reason="r", summary="s", runner=lambda job: "y")
        assert _wait_for(lambda: escalation.get_job(job_id)["status"] == "done")
        assert seen == []
        assert escalation.pending_count("sess-6") == 1

    def test_job_carries_the_reason_and_summary_to_the_runner(self):
        captured = {}

        def _runner(job):
            captured.update(job)
            return "ok"

        escalation.start_escalation(
            session_id="s", reason="needs tools", summary="do the thing",
            model="claude-opus-5", runner=_runner)
        assert _wait_for(lambda: captured)
        assert captured["reason"] == "needs tools"
        assert captured["summary"] == "do the thing"
        assert captured["model"] == "claude-opus-5"


def test_handoff_tool_registered_and_empty_results_not_delivered(monkeypatch):
    from agent import escalation as esc
    from tools.registry import registry
    assert registry.get_definitions({"handoff"})
    delivered = []
    monkeypatch.setattr(esc, "deliver", lambda sid, data, **k: delivered.append(data))
    with esc._lock:
        esc._jobs["j1"] = {"job_id": "j1", "session_id": "s1"}
    esc._run_job("j1", lambda job: "")
    assert delivered == []


def test_has_live_sink():
    from agent import escalation as esc

    def sink(event, data):
        return None

    esc.register_stream_sink("sx", sink)
    assert esc.has_live_sink("sx")
    esc.unregister_stream_sink("sx", sink)
    assert not esc.has_live_sink("sx")


class TestAutoHandoff:
    """A fast model that will not hand off on its own is handed off by the server
    once it has used more tool calls than a quick answer needs."""

    def _bind(self, runner, after=2):
        escalation.bind_turn_context("sess-auto", session_id="sess-auto", runner=runner,
                                     question="set up my shopping list", auto_handoff_after=after)

    def test_tool_calls_within_the_budget_run(self):
        self._bind(lambda job: "done", after=2)
        assert escalation.auto_handoff_block("registry_get", "sess-auto") is None
        assert escalation.auto_handoff_block("registry_put", "sess-auto") is None

    def test_the_call_past_the_budget_hands_off_once(self):
        jobs = []
        started = threading.Event()

        def _runner(job):
            jobs.append(job)
            started.set()
            return "claude's answer"

        self._bind(_runner, after=2)
        escalation.auto_handoff_block("a", "sess-auto")
        escalation.auto_handoff_block("b", "sess-auto")
        msg = escalation.auto_handoff_block("c", "sess-auto")
        assert msg and "handed" in msg.lower()
        assert started.wait(5)
        assert "set up my shopping list" in jobs[0]["summary"]
        # Everything after the hand-off is stopped too, without a second job.
        assert escalation.auto_handoff_block("d", "sess-auto")
        time.sleep(0.1)
        assert len(jobs) == 1

    def test_bridge_and_search_calls_do_not_count(self):
        self._bind(lambda job: "done", after=1)
        assert escalation.auto_handoff_block("tool_search", "sess-auto") is None
        assert escalation.auto_handoff_block("tool_call", "sess-auto") is None
        assert escalation.auto_handoff_block("registry_get", "sess-auto") is None
        assert escalation.auto_handoff_block("tool_call", "sess-auto") is None

    def test_a_handoff_the_model_made_itself_stops_the_counting(self):
        self._bind(lambda job: "done", after=1)
        escalation.auto_handoff_block("handoff", "sess-auto")
        escalation.mark_handed_off("sess-auto")
        assert escalation.auto_handoff_block("registry_get", "sess-auto")

    def test_turns_without_a_budget_are_untouched(self):
        escalation.bind_turn_context("plain", session_id="plain", runner=lambda job: "x")
        for name in ("a", "b", "c", "d", "e"):
            assert escalation.auto_handoff_block(name, "plain") is None

    def test_the_pre_tool_gate_applies_it(self):
        from jarviscopilot_cli.plugins import get_pre_tool_call_block_message

        self._bind(lambda job: "done", after=0)
        assert get_pre_tool_call_block_message("registry_get", {}, task_id="sess-auto")
