"""Anthropic thinking blocks never reach a provider that can't read them."""
from agent.agent_runtime_helpers import strip_foreign_thinking

ANTHROPIC = [{"type": "thinking", "thinking": "", "signature": "s"}]


def test_kept_for_anthropic_messages():
    msg = {"role": "assistant", "content": "a", "reasoning_details": list(ANTHROPIC)}
    strip_foreign_thinking(msg, api_mode="anthropic_messages", base_url="")
    assert msg["reasoning_details"] == ANTHROPIC


def test_dropped_for_chat_completions():
    msg = {"role": "assistant", "content": "a", "reasoning_details": list(ANTHROPIC)}
    strip_foreign_thinking(msg, api_mode="chat_completions", base_url="https://ollama.com/v1")
    assert "reasoning_details" not in msg


def test_openrouter_details_untouched():
    details = [{"type": "reasoning.encrypted", "data": "x"}]
    msg = {"role": "assistant", "content": "a", "reasoning_details": list(details)}
    strip_foreign_thinking(msg, api_mode="chat_completions", base_url="https://openrouter.ai/api/v1")
    assert msg["reasoning_details"] == details


def test_non_anthropic_details_untouched_elsewhere():
    details = [{"type": "reasoning.text", "text": "x"}]
    msg = {"role": "assistant", "content": "a", "reasoning_details": list(details)}
    strip_foreign_thinking(msg, api_mode="chat_completions", base_url="https://api.x.ai/v1")
    assert msg["reasoning_details"] == details
