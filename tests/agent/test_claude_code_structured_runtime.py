"""Tests for the structured-engine runtime glue (agent/claude_code_structured_runtime.py).

The unit tests stub out ``run_structured_turn`` so they need neither the ``claude``
CLI nor a subscription — they verify the WIRING: prompt construction, tool routing
through ``agent._invoke_tool``, live streaming, status callbacks, the returned
OpenAI-shaped response, and interrupt handling.

The e2e test (``test_e2e_structured_completes_tool_task``) drives the REAL CLI and
is skipped unless ``RUN_CLAUDE_CODE_E2E=1`` — it is the proof that a "let me do X"
turn becomes an actual tool call instead of being silently abandoned.
"""
from __future__ import annotations

import os
import threading
from types import SimpleNamespace

import pytest

import agent.claude_code_structured_runtime as rt


# ── fakes ────────────────────────────────────────────────────────────────────
class FakeAgent:
    def __init__(self):
        self.provider = "claude-code"
        self._current_task_id = "task-123"
        self._interrupt_requested = False
        self._current_tool = None
        self._stream_needs_break = False
        self.tool_progress_callback = None
        self.tool_start_callback = None
        self.tool_complete_callback = None
        self.tool_gen_callback = None
        # interrupt fan-out tracking (mirrors AIAgent)
        self._tool_worker_threads = set()
        self._tool_worker_threads_lock = threading.Lock()
        self._set_interrupt_calls = []
        # observability
        self.streamed = []
        self.invoked = []
        self.started = []
        self.completed = []
        self.activity = []
        self.tids_seen_during_tool = []

    def _fire_stream_delta(self, text):
        self.streamed.append(text)

    def _fire_tool_gen_started(self, name):
        pass

    def _has_stream_consumers(self):
        return True

    def _touch_activity(self, msg):
        self.activity.append(msg)

    def _set_interrupt(self, value, tid):
        self._set_interrupt_calls.append((value, tid))

    def _invoke_tool(self, name, args, task_id, tool_call_id=None, messages=None, pre_tool_block_checked=False):
        self.invoked.append((name, dict(args), task_id, tool_call_id))
        # snapshot the worker-thread registry WHILE the tool runs
        with self._tool_worker_threads_lock:
            self.tids_seen_during_tool.append(set(self._tool_worker_threads))
        return f"result::{name}"


# ── should_use_structured ────────────────────────────────────────────────────
def test_should_use_structured_only_for_claude_code_with_flag(monkeypatch):
    monkeypatch.setenv("HERMES_CLAUDE_CODE_STRUCTURED", "1")
    assert rt.should_use_structured(FakeAgent()) is True

    other = FakeAgent(); other.provider = "openai-codex"
    assert rt.should_use_structured(other) is False


def test_should_use_structured_default_on(monkeypatch):
    # Default ON for claude-code (the proven path); no flag needed.
    monkeypatch.delenv("HERMES_CLAUDE_CODE_STRUCTURED", raising=False)
    assert rt.should_use_structured(FakeAgent()) is True


def test_should_use_structured_explicit_off(monkeypatch):
    # The text-shim escape hatch: HERMES_CLAUDE_CODE_STRUCTURED=0 disables it.
    monkeypatch.setenv("HERMES_CLAUDE_CODE_STRUCTURED", "0")
    assert rt.should_use_structured(FakeAgent()) is False


def test_should_use_structured_falls_back_for_vision_turns(monkeypatch):
    """Images must route to the text-shim's vision path, not the text-only
    structured stdin (which would silently drop them)."""
    monkeypatch.setenv("HERMES_CLAUDE_CODE_STRUCTURED", "1")
    text_only = {"messages": [{"role": "user", "content": "hi"}]}
    assert rt.should_use_structured(FakeAgent(), text_only) is True

    with_image = {"messages": [{"role": "user", "content": [
        {"type": "text", "text": "what is this?"},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64,iVBORw0KGgo="}},
    ]}]}
    assert rt.should_use_structured(FakeAgent(), with_image) is False


# ── prompt construction ──────────────────────────────────────────────────────
def test_build_user_text_folds_system_and_drops_tool_call_dsl():
    messages = [
        {"role": "system", "content": "You are JARVIS. Skills: x, y."},
        {"role": "user", "content": "fix the segmented bar"},
    ]
    text = rt._build_user_text(messages, model="claude-opus-4-8")
    assert "<system>" in text and "You are JARVIS" in text
    assert "fix the segmented bar" in text
    # Native tools now — the legacy text DSL must NOT be instructed.
    assert "<tool_call>" not in text


# ── the wiring (stubbed CLI) ─────────────────────────────────────────────────
def _stub_run_structured_turn(captured):
    """Return a fake run_structured_turn that exercises the glue's callbacks."""
    def _fake(*, user_text, tools, execute_tool, command, model_cli,
              system_prompt, on_text=None, should_abort=None, **kw):
        captured["user_text"] = user_text
        captured["tools"] = tools
        captured["model_cli"] = model_cli
        # simulate the CLI streaming text + calling a tool mid-turn
        if on_text:
            on_text("Reading the file ")
        r = execute_tool("read_file", {"path": "bar.swift"})
        captured["tool_result"] = r
        if on_text:
            on_text("— done.")
        return SimpleNamespace(
            text="Reading the file — done.",
            tool_events=[{"name": "read_file", "arguments": {"path": "bar.swift"}, "result": r}],
            is_error=False, error=None,
            usage={"input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 30},
        )
    return _fake


def test_run_structured_response_wires_tools_streaming_and_shape(monkeypatch):
    monkeypatch.setenv("HERMES_CLAUDE_CODE_STRUCTURED", "1")
    captured = {}
    monkeypatch.setattr(rt, "run_structured_turn", _stub_run_structured_turn(captured))

    agent = FakeAgent()
    starts, completes = [], []
    agent.tool_start_callback = lambda tcid, name, args: starts.append((tcid, name))
    agent.tool_complete_callback = lambda tcid, name, args, result: completes.append((name, result))

    api_kwargs = {
        "model": "claude-opus-4-8",
        "messages": [
            {"role": "system", "content": "sys"},
            {"role": "user", "content": "read bar.swift"},
        ],
        "tools": [{"type": "function", "function": {"name": "read_file", "parameters": {}}}],
    }
    resp = rt.run_claude_structured_response(agent, api_kwargs)

    # tool routed through agent._invoke_tool with the active task id
    assert agent.invoked and agent.invoked[0][0] == "read_file"
    assert agent.invoked[0][2] == "task-123"
    assert captured["tool_result"] == "result::read_file"
    # live streaming reached the agent
    assert agent.streamed == ["Reading the file ", "— done."]
    # status callbacks fired
    assert starts and starts[0][1] == "read_file"
    assert completes and completes[0] == ("read_file", "result::read_file")
    # OpenAI-shaped response, no tool_calls, finish_reason stop, usage summed
    msg = resp.choices[0].message
    assert msg.content == "Reading the file — done."
    assert msg.tool_calls == []
    assert resp.choices[0].finish_reason == "stop"
    assert resp.usage.prompt_tokens == 100 and resp.usage.completion_tokens == 20
    assert resp.usage.total_tokens == 120
    assert resp.usage.prompt_tokens_details.cached_tokens == 30


def test_execute_tool_registers_worker_tid_for_interrupt(monkeypatch):
    """The bridge runs tools off the main loop thread, so the worker tid must be
    registered in _tool_worker_threads while the tool runs (so interrupt fan-out
    reaches it) and removed afterwards."""
    monkeypatch.setenv("HERMES_CLAUDE_CODE_STRUCTURED", "1")
    captured = {}
    monkeypatch.setattr(rt, "run_structured_turn", _stub_run_structured_turn(captured))

    agent = FakeAgent()
    rt.run_claude_structured_response(agent, {
        "model": "m", "messages": [{"role": "user", "content": "go"}],
        "tools": [{"type": "function", "function": {"name": "read_file", "parameters": {}}}],
    })
    # a tid was registered while the tool executed...
    assert agent.tids_seen_during_tool and agent.tids_seen_during_tool[0], \
        "worker tid was not registered during tool execution"
    # ...and cleaned up afterwards (no leak)
    assert agent._tool_worker_threads == set()


def test_execute_tool_reports_error_state_to_progress(monkeypatch):
    """A tool that returns a JSON error envelope must surface is_error=True to the
    progress UI rather than rendering as a clean success."""
    monkeypatch.setenv("HERMES_CLAUDE_CODE_STRUCTURED", "1")

    def _fake(*, execute_tool, on_text=None, should_abort=None, **kw):
        execute_tool("boom", {})
        return SimpleNamespace(text="ok", tool_events=[], is_error=False, error=None, usage={})
    monkeypatch.setattr(rt, "run_structured_turn", _fake)

    agent = FakeAgent()
    agent._invoke_tool = lambda *a, **k: '{"error": "kaboom"}'
    progress = []
    agent.tool_progress_callback = lambda *a, **k: progress.append((a, k))
    rt.run_claude_structured_response(agent, {"messages": [], "tools": []})

    completed = [p for p in progress if p[0][0] == "tool.completed"]
    assert completed, "no tool.completed event emitted"
    assert completed[0][1].get("is_error") is True


def test_run_structured_response_raises_on_interrupt(monkeypatch):
    monkeypatch.setenv("HERMES_CLAUDE_CODE_STRUCTURED", "1")

    def _fake(*, should_abort=None, on_text=None, execute_tool=None, **kw):
        return SimpleNamespace(text="", tool_events=[], is_error=True,
                               error="aborted", usage={})
    monkeypatch.setattr(rt, "run_structured_turn", _fake)

    agent = FakeAgent()
    agent._interrupt_requested = True
    with pytest.raises(InterruptedError):
        rt.run_claude_structured_response(agent, {"messages": [], "tools": []})


def test_run_structured_response_raises_on_hard_error(monkeypatch):
    monkeypatch.setenv("HERMES_CLAUDE_CODE_STRUCTURED", "1")

    def _fake(*, should_abort=None, on_text=None, execute_tool=None, **kw):
        return SimpleNamespace(text="", tool_events=[], is_error=True,
                               error="CLI exploded", usage={})
    monkeypatch.setattr(rt, "run_structured_turn", _fake)

    with pytest.raises(RuntimeError, match="CLI exploded"):
        rt.run_claude_structured_response(FakeAgent(), {"messages": [], "tools": []})


# ── real-CLI e2e (opt-in) ────────────────────────────────────────────────────
@pytest.mark.skipif(
    os.environ.get("RUN_CLAUDE_CODE_E2E") != "1",
    reason="needs the real `claude` CLI + Claude subscription (set RUN_CLAUDE_CODE_E2E=1)",
)
def test_e2e_structured_completes_tool_task():
    """A 'let me check X' style request must actually CALL the tool and use its
    result — the exact failure the text-shim hits. Drives the real CLI."""
    from agent.claude_code_structured import run_structured_turn

    calls = []

    def execute_tool(name, args):
        calls.append((name, args))
        if name == "get_balance":
            return '{"balance": 1000}'
        if name == "apply_discount":
            pct = args.get("percent", 0)
            return f'{{"new_balance": {1000 * (100 - pct) // 100}}}'
        return "{}"

    tools = [
        {"type": "function", "function": {
            "name": "get_balance",
            "description": "Get the account balance in dollars.",
            "parameters": {"type": "object", "properties": {}},
        }},
        {"type": "function", "function": {
            "name": "apply_discount",
            "description": "Apply a percentage discount to the balance.",
            "parameters": {"type": "object",
                           "properties": {"percent": {"type": "number"}},
                           "required": ["percent"]},
        }},
    ]

    res = run_structured_turn(
        user_text="Check my balance, then apply a 15% discount and tell me the new balance.",
        tools=tools, execute_tool=execute_tool,
    )
    names = [c[0] for c in calls]
    assert "get_balance" in names, f"model never called get_balance; calls={calls}"
    assert "apply_discount" in names, f"model never called apply_discount; calls={calls}"
    assert not res.is_error, f"turn errored: {res.error}"
    assert "850" in res.text, f"final answer missing new balance: {res.text!r}"
