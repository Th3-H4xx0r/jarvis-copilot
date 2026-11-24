"""Memory prefetch runs alongside turn setup instead of after it."""
import threading
import time
from pathlib import Path
from types import SimpleNamespace

from agent.conversation_loop import start_memory_prefetch


class _MM:
    def __init__(self, delay=0.0, fail=False):
        self.calls = []
        self.delay, self.fail = delay, fail

    def on_turn_start(self, turn, msg, recent_messages=None):
        self.calls.append(("start", turn, msg, recent_messages))

    def prefetch_all(self, query):
        self.calls.append(("prefetch", query))
        time.sleep(self.delay)
        if self.fail:
            raise RuntimeError("embed timeout")
        return "<memory-context>\nCOTA trip Friday"


def test_prefetch_runs_in_background_and_collects():
    mm = _MM(delay=0.2)
    agent = SimpleNamespace(_memory_manager=mm, _user_turn_count=3)
    t0 = time.monotonic()
    collect = start_memory_prefetch(agent, "where is the venue", [{"role": "user", "content": "x"}])
    assert time.monotonic() - t0 < 0.1  # did not wait for the slow prefetch
    assert collect() == "<memory-context>\nCOTA trip Friday"
    assert mm.calls[0] == ("start", 3, "where is the venue", [{"role": "user", "content": "x"}])
    assert mm.calls[1] == ("prefetch", "where is the venue")


def test_prefetch_failure_is_empty():
    agent = SimpleNamespace(_memory_manager=_MM(fail=True), _user_turn_count=1)
    assert start_memory_prefetch(agent, "q", [])() == ""


def test_no_memory_manager_is_empty():
    assert start_memory_prefetch(SimpleNamespace(_memory_manager=None, _user_turn_count=0), "q", [])() == ""


def test_prefetch_starts_before_prompt_build():
    src = (Path(__file__).resolve().parents[2] / "agent" / "conversation_loop.py").read_text()
    assert src.index("_collect_memory = start_memory_prefetch(") < src.index(
        "_restore_or_build_system_prompt(agent, system_message, conversation_history)\n\n    active_system_prompt")
    assert "_ext_prefetch_cache = _collect_memory()" in src
