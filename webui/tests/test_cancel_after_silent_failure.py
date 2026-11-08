"""A cancel that lands after the agent returned no reply ends the turn cleanly.

The silent-failure branch's cancel used ``_pre_err``, which only the earlier
cancel branch (the one that always returns) ever bound, so it raised
UnboundLocalError: the turn fell into the exception handler, which journaled it
as interrupted a second time and sent a bare cancel without the provider error.
"""
import queue
import sys
import types
from unittest import mock

_MISSING = object()


class _FakeSession:
    def __init__(self, session_id, stream_id):
        self.session_id = session_id
        self.title = "t"
        self.workspace = "/tmp"
        self.model = "gpt-5.4"
        self.model_provider = None
        self.profile = None
        self.personality = None
        self.messages = []
        self.context_messages = []
        self.input_tokens = self.output_tokens = 0
        self.estimated_cost = 0
        self.cache_read_tokens = self.cache_write_tokens = 0
        self.tool_calls = []
        self.gateway_routing = None
        self.gateway_routing_history = []
        self.active_stream_id = stream_id
        self.pending_user_message = None
        self.pending_attachments = []
        self.pending_started_at = None
        self.context_length = self.threshold_tokens = self.last_prompt_tokens = 0
        self.llm_title_generated = True
        self.saves = 0

    def save(self, *args, **kwargs):
        self.saves += 1

    def compact(self):
        return {"session_id": self.session_id, "title": self.title, "workspace": self.workspace,
                "model": self.model, "created_at": 0, "updated_at": 0, "pinned": False,
                "archived": False, "project_id": None, "profile": None}


def _run(name, last_error, cancel_in_run=False):
    import api.streaming as streaming

    # A fresh session per run: the worker keeps a warm agent per session.
    stream_id = f"stream_{name}"
    session = _FakeSession(name, stream_id)

    class Agent:
        def __init__(self, **kwargs):
            self.session_id = kwargs.get("session_id")
            self.context_compressor = None
            self.session_prompt_tokens = self.session_completion_tokens = 0
            self.session_estimated_cost_usd = 0
            self.session_cache_read_tokens = self.session_cache_write_tokens = 0
            self.reasoning_config = None
            self.ephemeral_system_prompt = None
            self._last_error = last_error

        def run_conversation(self, **kwargs):
            if cancel_in_run:  # Stop pressed while the agent was running
                streaming.CANCEL_FLAGS[stream_id].set()
            # no assistant reply, no streamed tokens
            return {"messages": list(kwargs.get("conversation_history", []))
                    + [{"role": "user", "content": kwargs["persist_user_message"]}]}

        def interrupt(self, _message):
            pass

    def cancel_during_merge(*_a, **_k):
        # The user hits Stop after the post-run cancel checks have passed.
        streaming.CANCEL_FLAGS[stream_id].set()
        return False

    journal = []
    q = queue.Queue()
    runtime = types.ModuleType("jarviscopilot_cli.runtime_provider")
    runtime.resolve_runtime_provider = mock.Mock(return_value={
        "provider": "openai", "base_url": None, "api_key": "sk-test",
        "api_mode": "chat_completions", "command": None, "args": [], "credential_pool": None})
    cli_pkg = types.ModuleType("jarviscopilot_cli")
    cli_pkg.runtime_provider = runtime
    state = types.ModuleType("jarviscopilot_state")
    state.SessionDB = mock.Mock(return_value=None)
    injected = {"jarviscopilot_cli": cli_pkg, "jarviscopilot_cli.runtime_provider": runtime,
                "jarviscopilot_state": state}
    saved = {k: sys.modules.get(k, _MISSING) for k in injected}
    sys.modules.update(injected)
    try:
        with mock.patch.object(streaming, "get_session", return_value=session), \
             mock.patch.object(streaming, "_get_ai_agent", return_value=Agent), \
             mock.patch.object(streaming, "resolve_model_provider", return_value=("gpt-5.4", "openai", None)), \
             mock.patch.object(streaming, "_assistant_reply_added_after_current_turn", cancel_during_merge), \
             mock.patch.object(streaming, "append_turn_journal_event_for_stream",
                               lambda sid, st, ev: journal.append(ev)), \
             mock.patch("api.config.get_config", return_value={}), \
             mock.patch("api.config._resolve_cli_toolsets", return_value=[]):
            streaming.STREAMS[stream_id] = q
            streaming._run_agent_streaming(session_id=session.session_id, msg_text="hi",
                                           model="gpt-5.4", workspace="/tmp", stream_id=stream_id)
    finally:
        streaming.STREAMS.pop(stream_id, None)
        for k, prev in saved.items():
            if prev is _MISSING:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = prev
    events = list(q.queue)
    return events, journal


def test_the_cancel_carries_the_provider_error_it_interrupted(cleanup_test_sessions):
    events, journal = _run("cancel_after_silent_failure_429", "HTTP 429: rate limited, retrying")
    cancels = [data for name, data in events if name == "cancel"]
    assert len(cancels) == 1, events
    assert cancels[0]["type"] == "rate_limit"
    assert cancels[0]["hint"] == "HTTP 429: rate limited, retrying"
    assert cancels[0]["message"].startswith("Cancelled while retrying after a provider error")
    assert [e for e in journal if e.get("event") == "interrupted"] == [
        {"event": "interrupted", "created_at": mock.ANY, "reason": "cancelled"}]


def test_a_plain_cancel_is_cancelled_by_user(cleanup_test_sessions):
    events, journal = _run("cancel_after_silent_failure_plain", None)
    cancels = [data for name, data in events if name == "cancel"]
    assert cancels == [{"message": "Cancelled by user", "type": "cancel", "hint": ""}]
    assert sum(1 for e in journal if e.get("event") == "interrupted") == 1


def test_a_cancel_during_the_run_sends_one_cancel_and_one_journal_entry(cleanup_test_sessions):
    events, journal = _run("cancel_during_run", None, cancel_in_run=True)
    assert [(name, data) for name, data in events if name == "cancel"] == [
        ("cancel", {"message": "Cancelled by user"})]
    assert [e["reason"] for e in journal if e.get("event") == "interrupted"] == ["cancelled"]
