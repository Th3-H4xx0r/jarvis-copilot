"""Plan 2.4 — dispatch a device tool the moment its argument stream closes.

With ``eager_input_streaming`` the model's ``open_app{"name":"Safari"}`` arguments
are complete at ``content_block_stop`` for that block, typically hundreds of
milliseconds before ``message_stop``. For a small allow-list of device tools we
start executing right there instead of waiting for the whole message; the agent
loop then picks up the memoized result instead of running the tool a second
time.
"""
from __future__ import annotations

import json
import threading
import time
from types import SimpleNamespace

import pytest

import model_tools
from agent import chat_completion_helpers as cch
from tools.registry import registry


@pytest.fixture(autouse=True)
def _clean_eager():
    model_tools.reset_eager_dispatch()
    yield
    model_tools.reset_eager_dispatch()


@pytest.fixture
def counting_tool():
    calls = []

    def _handler(args, **kw):
        calls.append(dict(args))
        time.sleep(0.01)
        return json.dumps({"opened": args.get("name")})

    registry.register(
        name="open_app",
        toolset="devices",
        schema={"name": "open_app", "description": "Open an app",
                "parameters": {"type": "object",
                               "properties": {"name": {"type": "string"}}}},
        handler=_handler,
    )
    try:
        yield calls
    finally:
        registry.deregister("open_app")


class TestEagerAllowList:
    @pytest.mark.parametrize("name", [
        "open_app", "open_url", "flashlight_on", "flashlight_off",
        "set_volume", "notify", "chrome_navigate",
    ])
    def test_side_effect_safe_device_tools_are_eager(self, name):
        assert cch.is_eager_dispatchable(name) is True

    @pytest.mark.parametrize("name", [
        "write_file", "terminal", "delegate_task", "send_message", "patch",
        "memory", "escalate",
    ])
    def test_everything_else_is_not(self, name):
        assert cch.is_eager_dispatchable(name) is False


class TestEagerMemoization:
    def test_tool_runs_once_and_result_is_reused(self, counting_tool):
        model_tools.eager_dispatch(
            "open_app", {"name": "Safari"}, tool_call_id="toolu_1", task_id="t",
        )
        result = model_tools.handle_function_call(
            "open_app", {"name": "Safari"}, "t", tool_call_id="toolu_1",
        )
        assert json.loads(result)["opened"] == "Safari"
        assert len(counting_tool) == 1, "tool executed twice — eager result not reused"

    def test_unknown_tool_call_id_runs_normally(self, counting_tool):
        result = model_tools.handle_function_call(
            "open_app", {"name": "Mail"}, "t", tool_call_id="toolu_never_eager",
        )
        assert json.loads(result)["opened"] == "Mail"
        assert len(counting_tool) == 1

    def test_reset_drops_pending_results(self, counting_tool):
        model_tools.eager_dispatch(
            "open_app", {"name": "Safari"}, tool_call_id="toolu_2", task_id="t",
        )
        model_tools.reset_eager_dispatch()
        model_tools.handle_function_call(
            "open_app", {"name": "Safari"}, "t", tool_call_id="toolu_2",
        )
        # Ran eagerly AND again in the loop — the point is only that a stale
        # entry can never be handed to a different turn.
        assert len(counting_tool) == 2

    def test_a_failing_eager_tool_falls_back_to_the_normal_path(self):
        def _boom(args, **kw):
            raise RuntimeError("nope")

        registry.register(
            name="flashlight_on", toolset="devices",
            schema={"name": "flashlight_on", "description": "x",
                    "parameters": {"type": "object", "properties": {}}},
            handler=_boom,
        )
        try:
            model_tools.eager_dispatch(
                "flashlight_on", {}, tool_call_id="toolu_3", task_id="t",
            )
            out = model_tools.handle_function_call(
                "flashlight_on", {}, "t", tool_call_id="toolu_3",
            )
            assert "error" in json.loads(out)
        finally:
            registry.deregister("flashlight_on")


class _Block(SimpleNamespace):
    pass


def _events_for(tool_name: str, arg_chunks: list[str], index: int = 0):
    """Anthropic streaming events for one tool_use block."""
    yield SimpleNamespace(
        type="content_block_start",
        index=index,
        content_block=_Block(type="tool_use", id=f"toolu_{index}", name=tool_name, input={}),
    )
    for chunk in arg_chunks:
        yield SimpleNamespace(
            type="content_block_delta",
            index=index,
            delta=SimpleNamespace(type="input_json_delta", partial_json=chunk),
        )
    yield SimpleNamespace(type="content_block_stop", index=index)


class TestEagerDispatchSafetyGates:
    """Eager execution runs on a pool thread, ahead of the loop's own gates."""

    def test_declined_when_a_thread_tool_whitelist_is_active(self, counting_tool):
        from jarviscopilot_cli import plugins

        plugins.set_thread_tool_whitelist({"something_else"})
        try:
            assert model_tools.eager_dispatch(
                "open_app", {"name": "Safari"}, tool_call_id="toolu_w") is False
            assert counting_tool == []
        finally:
            plugins.set_thread_tool_whitelist(None)

    def test_declined_when_a_pre_tool_call_hook_is_registered(self, counting_tool,
                                                              monkeypatch):
        from jarviscopilot_cli import plugins

        class _Manager:
            _hooks = {"pre_tool_call": [lambda **kw: None]}

        monkeypatch.setattr(plugins, "_plugin_manager", _Manager(), raising=False)
        assert model_tools.eager_dispatch(
            "open_app", {"name": "Safari"}, tool_call_id="toolu_h") is False
        assert counting_tool == []

    def test_allowed_when_neither_gate_is_present(self, counting_tool, monkeypatch):
        from jarviscopilot_cli import plugins

        class _Manager:
            _hooks: dict = {}

        monkeypatch.setattr(plugins, "_plugin_manager", _Manager(), raising=False)
        assert model_tools.eager_dispatch(
            "open_app", {"name": "Safari"}, tool_call_id="toolu_ok") is True


class TestEagerStreamTracker:
    def test_dispatches_when_the_arg_stream_closes(self):
        seen = []
        tracker = cch.EagerToolStreamTracker(
            dispatch=lambda tid, name, args: seen.append((tid, name, args))
        )
        for ev in _events_for("open_app", ['{"na', 'me": "Saf', 'ari"}']):
            tracker.on_event(ev)
        assert seen == [("toolu_0", "open_app", {"name": "Safari"})]

    def test_ignores_tools_outside_the_allow_list(self):
        seen = []
        tracker = cch.EagerToolStreamTracker(dispatch=lambda *a: seen.append(a))
        for ev in _events_for("write_file", ['{"path": "/tmp/x"}']):
            tracker.on_event(ev)
        assert seen == []

    def test_malformed_partial_json_is_skipped_not_raised(self):
        seen = []
        tracker = cch.EagerToolStreamTracker(dispatch=lambda *a: seen.append(a))
        for ev in _events_for("open_app", ['{"name": ']):
            tracker.on_event(ev)
        assert seen == []

    def test_parallel_blocks_each_dispatch_once(self):
        seen = []
        tracker = cch.EagerToolStreamTracker(
            dispatch=lambda tid, name, args: seen.append((tid, name, args))
        )
        for ev in _events_for("open_app", ['{"name":"A"}'], index=0):
            tracker.on_event(ev)
        for ev in _events_for("open_url", ['{"url":"http://x"}'], index=1):
            tracker.on_event(ev)
        assert [s[1] for s in seen] == ["open_app", "open_url"]
        assert [s[0] for s in seen] == ["toolu_0", "toolu_1"]

    def test_sdk_accumulated_block_wins_over_reassembled_json(self):
        """The SDK's ContentBlockStopEvent carries the parsed input; prefer it."""
        seen = []
        tracker = cch.EagerToolStreamTracker(
            dispatch=lambda tid, name, args: seen.append(args))
        tracker.on_event(SimpleNamespace(
            type="content_block_start", index=0,
            content_block=_Block(type="tool_use", id="toolu_0",
                                 name="open_app", input={})))
        tracker.on_event(SimpleNamespace(
            type="content_block_delta", index=0,
            delta=SimpleNamespace(type="input_json_delta", partial_json='{"name": "Saf')))
        tracker.on_event(SimpleNamespace(
            type="content_block_stop", index=0,
            content_block=_Block(type="tool_use", id="toolu_0", name="open_app",
                                 input={"name": "Safari"})))
        assert seen == [{"name": "Safari"}]

    def test_a_dispatch_error_never_breaks_the_stream(self):
        def _boom(*a):
            raise RuntimeError("dispatcher exploded")

        tracker = cch.EagerToolStreamTracker(dispatch=_boom)
        for ev in _events_for("open_app", ['{"name":"A"}']):
            tracker.on_event(ev)  # must not raise


class TestParallelToolResultsStayInOneMessage:
    """Eager dispatch must not change how tool results are assembled."""

    def test_two_tool_results_become_one_user_message(self):
        from agent.anthropic_adapter import convert_messages_to_anthropic

        _system, msgs = convert_messages_to_anthropic([
            {"role": "user", "content": "open safari and mail"},
            {"role": "assistant", "content": "", "tool_calls": [
                {"id": "toolu_0", "type": "function",
                 "function": {"name": "open_app", "arguments": '{"name":"Safari"}'}},
                {"id": "toolu_1", "type": "function",
                 "function": {"name": "open_app", "arguments": '{"name":"Mail"}'}},
            ]},
            {"role": "tool", "tool_call_id": "toolu_0", "name": "open_app", "content": "ok"},
            {"role": "tool", "tool_call_id": "toolu_1", "name": "open_app", "content": "ok"},
        ])
        tool_result_msgs = [
            m for m in msgs
            if m.get("role") == "user"
            and isinstance(m.get("content"), list)
            and any(b.get("type") == "tool_result" for b in m["content"])
        ]
        assert len(tool_result_msgs) == 1, "tool_results were split across messages"
        assert len([b for b in tool_result_msgs[0]["content"]
                    if b.get("type") == "tool_result"]) == 2


class TestEagerDispatchIsThreadSafe:
    def test_concurrent_dispatches_do_not_cross_results(self, counting_tool):
        ids = [f"toolu_p{i}" for i in range(8)]
        for i, tid in enumerate(ids):
            model_tools.eager_dispatch(
                "open_app", {"name": f"App{i}"}, tool_call_id=tid, task_id="t",
            )
        out = {}
        threads = [
            threading.Thread(
                target=lambda i=i, tid=tid: out.__setitem__(
                    tid,
                    model_tools.handle_function_call(
                        "open_app", {"name": f"App{i}"}, "t", tool_call_id=tid),
                )
            )
            for i, tid in enumerate(ids)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)
        for i, tid in enumerate(ids):
            assert json.loads(out[tid])["opened"] == f"App{i}"
        assert len(counting_tool) == len(ids)
