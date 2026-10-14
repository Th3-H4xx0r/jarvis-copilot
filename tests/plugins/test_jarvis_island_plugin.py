"""jarvis-island: Jarvis's own runs reported to the agent tracker like any
other coding agent (after coucou's Hermes plugin). Display only — it never
blocks, never raises, and leaves cron runs out."""
import importlib.util
import json
import os
import socket
import threading
import time
from pathlib import Path

import pytest

PLUGIN = Path(__file__).resolve().parents[2] / "plugins" / "jarvis-island" / "__init__.py"


def load():
    spec = importlib.util.spec_from_file_location("jarvis_island_under_test", PLUGIN)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def tracker(monkeypatch):
    path = f"/tmp/jci-{os.getpid()}-{time.monotonic_ns() % 100000}.sock"
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(16)
    frames = []

    def serve():
        while True:
            try:
                c, _ = srv.accept()
            except OSError:
                return
            buf = b""
            while b"\n" not in buf:
                chunk = c.recv(65536)
                if not chunk:
                    break
                buf += chunk
            if buf.strip():
                frames.append(json.loads(buf.split(b"\n", 1)[0]))
            c.close()

    threading.Thread(target=serve, daemon=True).start()
    mod = load()
    monkeypatch.setattr(mod, "_socket_path", lambda: path)
    yield mod, frames
    srv.close()
    os.unlink(path)


def wait(frames, n):
    end = time.time() + 2
    while len(frames) < n and time.time() < end:
        time.sleep(0.01)
    return frames


def test_a_turn_becomes_prompt_tool_stop(tracker):
    mod, frames = tracker
    mod._pre_llm_call(session_id="j1", user_message="weather?", platform="telegram", model="m")
    mod._pre_tool_call(tool_name="web_search", args={"query": "weather"}, session_id="j1",
                       tool_call_id="c1")
    mod._post_tool_call(tool_name="web_search", args={"query": "weather"}, result="{}",
                        session_id="j1", tool_call_id="c1")
    mod._post_llm_call(session_id="j1", assistant_response="Sunny.", platform="telegram")
    got = wait(frames, 4)
    assert [f["payload"]["hook_event_name"] for f in got] == [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
    assert all(f["agent"] == "jarvis" and f["kind"] == "event" for f in got)
    first = got[0]["payload"]
    assert first["session_id"] == "j1" and first["prompt"] == "weather?"
    assert first["jc_project"] == "Jarvis · telegram"
    assert got[1]["payload"]["tool_use_id"] == "c1"
    assert got[3]["payload"]["last_assistant_message"] == "Sunny."


def test_cron_runs_are_left_out(tracker):
    mod, frames = tracker
    mod._pre_llm_call(session_id="c1", user_message="check mail", platform="cron")
    mod._pre_tool_call(tool_name="terminal", args={}, session_id="c1")
    mod._post_llm_call(session_id="c1", assistant_response="ok", platform="cron")
    time.sleep(0.3)
    assert frames == []


def test_an_approval_shows_as_waiting_on_you(tracker):
    mod, frames = tracker
    mod._pre_llm_call(session_id="j2", user_message="clean up", platform="webui")
    mod._pre_tool_call(tool_name="terminal", args={"command": "rm -rf build"}, session_id="j2")
    mod._pre_approval_request(command="rm -rf build", description="recursive delete",
                              session_key="k", surface="gateway")
    got = wait(frames, 3)
    note = got[2]["payload"]
    assert note["hook_event_name"] == "Notification"
    assert note["notification_type"] == "permission_prompt"
    assert note["session_id"] == "j2" and "rm -rf build" in note["message"]


def test_no_tracker_never_raises():
    mod = load()
    mod._socket_path = lambda: "/tmp/jci-nobody-here.sock"
    mod._pre_llm_call(session_id="j", user_message="x", platform="cli")
    mod._post_llm_call(session_id="j", assistant_response="y", platform="cli")


def test_register_wires_the_hooks():
    mod = load()
    names = []

    class Ctx:
        def register_hook(self, name, fn):
            names.append(name)

    mod.register(Ctx())
    assert {"pre_llm_call", "pre_tool_call", "post_tool_call", "post_llm_call",
            "pre_approval_request"} <= set(names)
