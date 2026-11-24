"""Fixes from the token-diet branch review."""
import inspect
from types import SimpleNamespace


def test_persist_session_finalizes_api_copies():
    from run_agent import AIAgent
    assert "finalize_api_copies(messages)" in inspect.getsource(AIAgent._persist_session)


def test_estimate_ignores_api_blocks_and_image_data_in_api_content():
    from agent.model_metadata import _estimate_message_chars
    big = "data:image/png;base64," + "A" * 1_000_000
    msg = {"role": "user", "content": "look",
           "api_content": [{"type": "text", "text": "look"}, {"type": "image_url", "image_url": {"url": big}}],
           "api_blocks": [{"kind": "k", "sha": "s", "sent": True}]}
    assert _estimate_message_chars(msg) < 2_000
    text_msg = {"role": "user", "content": "hi", "api_content": "hi\n\n" + "x" * 1000}
    # Counted once (the API copy), not content + copy.
    assert 1000 < _estimate_message_chars(text_msg) < 1300


def test_compression_strips_thinking_from_kept_messages():
    from run_agent import AIAgent
    src = inspect.getsource(AIAgent._compress_context)
    assert "drop_thinking_blocks(" in src


def test_drop_thinking_blocks_only_removes_anthropic_thinking():
    from agent.agent_runtime_helpers import drop_thinking_blocks
    msgs = [
        {"role": "assistant", "content": "a", "reasoning_details": [{"type": "thinking", "signature": "s"}]},
        {"role": "assistant", "content": "b", "reasoning_details": [{"type": "reasoning.encrypted", "data": "x"}]},
        {"role": "user", "content": "c"},
    ]
    drop_thinking_blocks(msgs)
    assert "reasoning_details" not in msgs[0]
    assert msgs[1]["reasoning_details"] == [{"type": "reasoning.encrypted", "data": "x"}]


def test_gateway_replay_keeps_api_copy():
    from gateway.run import _build_replay_entry
    blocks = [{"kind": "k", "sha": "s", "sent": True}]
    entry = _build_replay_entry("user", "hi", {"role": "user", "content": "hi",
                                               "api_content": "hi\n\nnote", "api_blocks": blocks})
    assert entry["api_content"] == "hi\n\nnote" and entry["api_blocks"] == blocks


def test_async_call_llm_records_aux(monkeypatch):
    import asyncio

    import agent.auxiliary_client as aux
    from agent import usage_log
    seen = []
    monkeypatch.setattr(usage_log, "record", lambda source, **kw: seen.append(source))
    response = SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content="x"), finish_reason="stop")],
                               usage=SimpleNamespace(prompt_tokens=5, completion_tokens=1))
    client = SimpleNamespace(base_url="https://chatgpt.com/backend-api/codex")

    async def fake_await(c, **kw):
        return response

    def attempts(**kw):
        got = yield client, {"model": "gpt-6.1-terra"}
        return got

    monkeypatch.setattr(aux, "_llm_call_attempts", attempts)
    monkeypatch.setattr(aux, "_await_completion", fake_await)
    monkeypatch.setattr(aux, "_validate_llm_response", lambda r, task: r)
    out = asyncio.run(aux.async_call_llm("vision", messages=[]))
    assert out is response and seen == ["aux:vision"]
