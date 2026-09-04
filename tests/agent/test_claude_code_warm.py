"""Plan 2.7 — keep ONE ``claude`` process + MCP bridge alive per agent session.

The per-turn engine pays a full CLI cold boot + MCP handshake on every single
turn (300–1500 ms, the single biggest fixed tax on the chat path). Warm mode
keeps the process and its bridge alive and feeds it stream-json user messages
across turns; ``--no-session-persistence`` becomes conditional so a restarted
process can ``--resume`` where it left off.

The per-turn path must keep working exactly as before — it stays the default.
"""
from __future__ import annotations

import json
import os
import stat
import sys

import pytest

from agent import claude_code_structured as ccs
from agent import claude_code_structured_runtime as ccsr


FAKE_CLI = '''#!/usr/bin/env python3
"""Stand-in for the `claude` CLI: stream-json in, stream-json out."""
import json, os, sys

log = os.environ.get("FAKE_CLAUDE_LOG")
if log:
    with open(log, "a") as fh:
        fh.write("start " + json.dumps(sys.argv[1:]) + "\\n")

turn = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    text = msg["message"]["content"][0]["text"]
    turn += 1
    sys.stdout.write(json.dumps({
        "type": "assistant",
        "message": {"content": [{"type": "text", "text": "reply-%d" % turn}]},
    }) + "\\n")
    sys.stdout.flush()
    sys.stdout.write(json.dumps({
        "type": "result", "is_error": False, "result": "reply-%d" % turn,
        "session_id": "cli-sess-1",
        "usage": {"input_tokens": 1, "output_tokens": 2},
    }) + "\\n")
    sys.stdout.flush()
'''


@pytest.fixture
def fake_claude(tmp_path):
    path = tmp_path / "fake_claude.py"
    path.write_text(FAKE_CLI)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    log = tmp_path / "cli.log"
    return {"command": sys.executable, "script": str(path), "log": str(log)}


def _starts(log_path: str) -> list:
    if not os.path.exists(log_path):
        return []
    return [ln for ln in open(log_path).read().splitlines() if ln.startswith("start ")]


# ── argv ─────────────────────────────────────────────────────────────────────

class TestArgv:
    def test_per_turn_keeps_no_session_persistence(self):
        argv = ccs._build_argv("claude", "claude-opus-5", "{}", "sys")
        assert "--no-session-persistence" in argv

    def test_warm_drops_no_session_persistence(self):
        argv = ccs._build_argv("claude", "claude-opus-5", "{}", "sys",
                               persist_session=True)
        assert "--no-session-persistence" not in argv

    def test_resume_is_appended_when_a_session_id_is_known(self):
        argv = ccs._build_argv("claude", "claude-opus-5", "{}", "sys",
                               persist_session=True, resume_session_id="cli-sess-1")
        assert argv[argv.index("--resume") + 1] == "cli-sess-1"

    def test_resume_is_ignored_without_persistence(self):
        argv = ccs._build_argv("claude", "claude-opus-5", "{}", "sys",
                               resume_session_id="cli-sess-1")
        assert "--resume" not in argv


# ── config gating ────────────────────────────────────────────────────────────

class TestWarmGating:
    def test_off_by_default(self, monkeypatch):
        monkeypatch.setattr(ccsr, "_load_config", lambda: {})
        assert ccsr.warm_enabled() is False

    def test_enabled_by_config(self, monkeypatch):
        monkeypatch.setattr(ccsr, "_load_config", lambda: {"claude_code": {"warm": True}})
        assert ccsr.warm_enabled() is True

    def test_env_override(self, monkeypatch):
        monkeypatch.setattr(ccsr, "_load_config", lambda: {})
        monkeypatch.setenv("HERMES_CLAUDE_CODE_WARM", "1")
        assert ccsr.warm_enabled() is True


# ── warm session ─────────────────────────────────────────────────────────────

class TestWarmSession:
    def test_two_turns_share_one_process(self, fake_claude, monkeypatch):
        monkeypatch.setenv("FAKE_CLAUDE_LOG", fake_claude["log"])
        session = ccs.WarmStructuredSession(
            command=fake_claude["command"],
            extra_argv_prefix=[fake_claude["script"]],
            model_cli="claude-opus-5",
            system_prompt="sys",
            env={"FAKE_CLAUDE_LOG": fake_claude["log"]},
        )
        try:
            first = session.run_turn(user_text="hello", tools=[],
                                     execute_tool=lambda n, a: "{}")
            pid = session.pid
            second = session.run_turn(user_text="again", tools=[],
                                      execute_tool=lambda n, a: "{}")
            assert first.text == "reply-1"
            assert second.text == "reply-2", "second turn hit a cold process"
            assert session.pid == pid
            assert len(_starts(fake_claude["log"])) == 1, "CLI booted more than once"
        finally:
            session.close()

    def test_warm_argv_has_no_session_persistence_flag(self, fake_claude, monkeypatch):
        monkeypatch.setenv("FAKE_CLAUDE_LOG", fake_claude["log"])
        session = ccs.WarmStructuredSession(
            command=fake_claude["command"],
            extra_argv_prefix=[fake_claude["script"]],
            model_cli="claude-opus-5",
            system_prompt="sys",
            env={"FAKE_CLAUDE_LOG": fake_claude["log"]},
        )
        try:
            session.run_turn(user_text="hi", tools=[], execute_tool=lambda n, a: "{}")
            argv = json.loads(_starts(fake_claude["log"])[0][len("start "):])
            assert "--no-session-persistence" not in argv
            assert "--input-format" in argv and "stream-json" in argv
        finally:
            session.close()

    def test_close_is_idempotent_and_stops_the_process(self, fake_claude, monkeypatch):
        monkeypatch.setenv("FAKE_CLAUDE_LOG", fake_claude["log"])
        session = ccs.WarmStructuredSession(
            command=fake_claude["command"],
            extra_argv_prefix=[fake_claude["script"]],
            model_cli="claude-opus-5", system_prompt="sys",
            env={"FAKE_CLAUDE_LOG": fake_claude["log"]},
        )
        session.run_turn(user_text="hi", tools=[], execute_tool=lambda n, a: "{}")
        session.close()
        session.close()
        assert session.alive is False

    def test_a_dead_process_is_restarted_with_resume(self, fake_claude, monkeypatch):
        monkeypatch.setenv("FAKE_CLAUDE_LOG", fake_claude["log"])
        session = ccs.WarmStructuredSession(
            command=fake_claude["command"],
            extra_argv_prefix=[fake_claude["script"]],
            model_cli="claude-opus-5", system_prompt="sys",
            env={"FAKE_CLAUDE_LOG": fake_claude["log"]},
        )
        try:
            session.run_turn(user_text="hi", tools=[], execute_tool=lambda n, a: "{}")
            assert session.cli_session_id == "cli-sess-1"
            session._proc.kill()
            session._proc.wait(timeout=5)
            result = session.run_turn(user_text="again", tools=[],
                                      execute_tool=lambda n, a: "{}")
            assert result.text == "reply-1", "restarted process should serve the turn"
            starts = [json.loads(s[len("start "):]) for s in _starts(fake_claude["log"])]
            assert len(starts) == 2
            assert starts[1][starts[1].index("--resume") + 1] == "cli-sess-1"
        finally:
            session.close()


class TestWarmSessionRegistry:
    def test_same_agent_session_reuses_one_warm_session(self, monkeypatch):
        made = []

        class _Fake:
            def __init__(self, **kw):
                made.append(self)
                self.alive = True

            def close(self):
                self.alive = False

        monkeypatch.setattr(ccs, "WarmStructuredSession", _Fake)
        ccsr.close_all_warm_sessions()
        try:
            a = ccsr.get_warm_session("sid-1", model_cli="m", system_prompt="s")
            b = ccsr.get_warm_session("sid-1", model_cli="m", system_prompt="s")
            c = ccsr.get_warm_session("sid-2", model_cli="m", system_prompt="s")
            assert a is b
            assert c is not a
            assert len(made) == 2
        finally:
            ccsr.close_all_warm_sessions()

    def test_close_all_shuts_every_session_down(self, monkeypatch):
        class _Fake:
            def __init__(self, **kw):
                self.alive = True

            def close(self):
                self.alive = False

        monkeypatch.setattr(ccs, "WarmStructuredSession", _Fake)
        session = ccsr.get_warm_session("sid-x", model_cli="m", system_prompt="s")
        ccsr.close_all_warm_sessions()
        assert session.alive is False
        assert ccsr.warm_session_count() == 0


# ── bridge reuse ─────────────────────────────────────────────────────────────

class TestBridgeStaysAlive:
    def test_callback_and_tools_can_be_repointed_between_turns(self):
        from agent.claude_code_mcp_bridge import McpToolBridge

        bridge = McpToolBridge([{"name": "a", "description": "", "inputSchema": {}}],
                               lambda n, args: "first")
        try:
            assert bridge.handle_message(
                {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
            )["result"]["tools"][0]["name"] == "a"

            bridge.set_tools([{"name": "b", "description": "", "inputSchema": {}}])
            bridge.set_tool_callback(lambda n, args: "second")

            assert bridge.handle_message(
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
            )["result"]["tools"][0]["name"] == "b"
            out = bridge.handle_message({
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": {"name": "mcp__jc__b", "arguments": {}},
            })
            assert out["result"]["content"][0]["text"] == "second"
        finally:
            bridge.close()


class TestRuntimeRouting:
    """``run_claude_structured_response`` picks warm vs cold and degrades safely."""

    def _agent(self):
        class _Agent:
            provider = "claude-code"
            session_id = "agent-sess"
            model = "claude-opus-5"
            _interrupt_requested = False
            _current_task_id = "task"
            _current_tool = None
            _stream_needs_break = False

            def _has_stream_consumers(self):
                return False

            def _fire_stream_delta(self, text):
                pass

            def _touch_activity(self, *a):
                pass

            def _fire_tool_gen_started(self, *a):
                pass

            def _invoke_tool(self, *a, **kw):
                return "{}"

        return _Agent()

    def test_cold_path_when_warm_is_off(self, monkeypatch):
        monkeypatch.setattr(ccsr, "warm_enabled", lambda: False)
        calls = {"cold": 0, "warm": 0}
        monkeypatch.setattr(ccsr, "run_structured_turn", lambda **kw: (
            calls.__setitem__("cold", calls["cold"] + 1)
            or __import__("types").SimpleNamespace(
                text="cold answer", tool_events=[], is_error=False, error=None, usage={})
        ))
        monkeypatch.setattr(ccsr, "get_warm_session",
                            lambda *a, **kw: calls.__setitem__("warm", 1))
        resp = ccsr.run_claude_structured_response(
            self._agent(), {"messages": [{"role": "user", "content": "hi"}],
                            "tools": [], "model": "claude-opus-5"})
        assert resp.choices[0].message.content == "cold answer"
        assert calls == {"cold": 1, "warm": 0}

    def test_warm_path_sends_only_the_new_user_text_after_turn_one(self, monkeypatch):
        from types import SimpleNamespace

        monkeypatch.setattr(ccsr, "warm_enabled", lambda: True)
        sent = []

        class _Warm:
            model_cli = "claude-opus-5"
            turns = 1  # already served a turn

            def run_turn(self, *, user_text, **kw):
                sent.append(user_text)
                return SimpleNamespace(text="warm answer", tool_events=[],
                                       is_error=False, error=None, usage={})

        monkeypatch.setattr(ccsr, "get_warm_session", lambda *a, **kw: _Warm())
        monkeypatch.setattr(ccsr, "_map_model_to_cli", lambda m: "claude-opus-5",
                            raising=False)
        resp = ccsr.run_claude_structured_response(
            self._agent(),
            {"messages": [
                {"role": "system", "content": "big system prompt"},
                {"role": "user", "content": "older question"},
                {"role": "assistant", "content": "older answer"},
                {"role": "user", "content": "the new question"},
             ], "tools": [], "model": "claude-opus-5"})
        assert resp.choices[0].message.content == "warm answer"
        assert sent == ["the new question"], "warm turn replayed the whole history"

    def test_warm_failure_falls_back_to_cold(self, monkeypatch):
        from types import SimpleNamespace

        monkeypatch.setattr(ccsr, "warm_enabled", lambda: True)

        class _Warm:
            model_cli = "claude-opus-5"
            turns = 0

            def run_turn(self, **kw):
                raise RuntimeError("warm process is wedged")

        closed = []
        monkeypatch.setattr(ccsr, "get_warm_session", lambda *a, **kw: _Warm())
        monkeypatch.setattr(ccsr, "close_warm_session", lambda sid: closed.append(sid))
        monkeypatch.setattr(ccsr, "run_structured_turn", lambda **kw: SimpleNamespace(
            text="cold fallback", tool_events=[], is_error=False, error=None, usage={}))
        resp = ccsr.run_claude_structured_response(
            self._agent(), {"messages": [{"role": "user", "content": "hi"}],
                            "tools": [], "model": "claude-opus-5"})
        assert resp.choices[0].message.content == "cold fallback"
        assert closed == ["agent-sess"]


# ── the per-turn path is untouched ───────────────────────────────────────────

class TestPerTurnUnchanged:
    def test_run_structured_turn_still_spawns_per_turn(self, fake_claude, monkeypatch):
        monkeypatch.setenv("FAKE_CLAUDE_LOG", fake_claude["log"])
        for _ in range(2):
            res = ccs.run_structured_turn(
                user_text="hello",
                tools=[],
                execute_tool=lambda n, a: "{}",
                command=fake_claude["command"],
                model_cli="claude-opus-5",
                env={"FAKE_CLAUDE_LOG": fake_claude["log"]},
                extra_argv_prefix=[fake_claude["script"]],
            )
            assert res.is_error is False
            assert res.text == "reply-1"
        starts = [json.loads(s[len("start "):]) for s in _starts(fake_claude["log"])]
        assert len(starts) == 2, "per-turn mode must still boot a process per turn"
        assert all("--no-session-persistence" in a for a in starts)
