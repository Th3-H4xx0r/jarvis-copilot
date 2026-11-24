"""Web chat history keeps what the model needs to see its earlier turns unchanged."""
from api.streaming import _sanitize_messages_for_api


def _turn(details):
    return [
        {"role": "user", "content": "hi", "_ts": 1},
        {"role": "assistant", "content": "", "reasoning_details": details,
         "tool_calls": [{"id": "tc_1", "type": "function",
                         "function": {"name": "t", "arguments": "{}"}}]},
        {"role": "tool", "tool_call_id": "tc_1", "content": "ok"},
    ]


def test_api_safe_keys_keep_reasoning_details():
    details = [{"type": "thinking", "thinking": "", "signature": "sig_abc"}]
    out = _sanitize_messages_for_api(_turn(details))
    assert out[1]["reasoning_details"] == details
    assert "_ts" not in out[0]


def test_large_redacted_block_round_trips_unchanged():
    details = [{"type": "redacted_thinking", "data": "x" * 100_000}]
    out = _sanitize_messages_for_api(_turn(details))
    assert out[1]["reasoning_details"] == details
