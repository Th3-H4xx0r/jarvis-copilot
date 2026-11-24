"""Per-turn additions are kept with their user message and deduplicated, so a
user message's bytes never change after it is first sent (prompt cache)."""
from types import SimpleNamespace

from agent.turn_context import api_user_content, block_kind, dedupe_blocks, turn_blocks

VOICE = "[Voice mode — rules]\nSpeak briefly."
BRIEF_A = "<memory-context>\nnow: Tue 9:00\nCOTA trip Friday"
BRIEF_B = "<memory-context>\nnow: Tue 9:05\nCOTA trip Friday, gate C"


def _user(content, blocks=None, api=None):
    msg = {"role": "user", "content": content}
    if blocks is not None:
        msg["api_blocks"] = blocks
    if api is not None:
        msg["api_content"] = api
    return msg


def test_turn_blocks_kinds():
    blocks = turn_blocks([BRIEF_A, "", None], [VOICE, "  "])
    assert blocks == [
        {"kind": "<memory-context>", "text": BRIEF_A},
        {"kind": "[Voice mode — rules]", "text": VOICE},
    ]
    assert turn_blocks([], "Speaking device: watch") == [
        {"kind": "Speaking device: watch", "text": "Speaking device: watch"}]
    assert block_kind("\n\n  x" * 1 + "y" * 200).startswith("x") and len(block_kind("z" * 200)) == 80


def test_dedupe_skips_unchanged_latest_of_kind():
    prior = [_user("q1", turn_blocks([BRIEF_A], [VOICE]))]
    assert dedupe_blocks(turn_blocks([BRIEF_A], [VOICE]), prior) == []


def test_dedupe_looks_past_turns_that_sent_nothing_of_that_kind():
    prior = [_user("q1", turn_blocks([BRIEF_A], [])), _user("q2", [])]
    assert dedupe_blocks(turn_blocks([BRIEF_A], []), prior) == []


def test_dedupe_resends_after_change_and_revert():
    prior = [_user("q1", turn_blocks([BRIEF_A], [])), _user("q2", turn_blocks([BRIEF_B], []))]
    assert dedupe_blocks(turn_blocks([BRIEF_A], []), prior) == turn_blocks([BRIEF_A], [])


def test_block_dropped_by_compression_is_resent():
    prior = [{"role": "user", "content": "[summary of earlier turns]"}]
    assert dedupe_blocks(turn_blocks([BRIEF_A], [VOICE]), prior) == turn_blocks([BRIEF_A], [VOICE])


def test_api_user_content_str_and_list():
    blocks = turn_blocks([BRIEF_A], [VOICE])
    assert api_user_content("hi", blocks) == "hi\n\n" + BRIEF_A + "\n\n" + VOICE
    parts = [{"type": "text", "text": "look"}, {"type": "image_url", "image_url": {"url": "data:x"}}]
    out = api_user_content(parts, blocks)
    assert out[:2] == parts and out[2] == {"type": "text", "text": BRIEF_A + "\n\n" + VOICE}
    assert api_user_content("hi", []) == "hi"


# ── the loop's API build ─────────────────────────────────────────────────────

def _agent(turn_context=""):
    return SimpleNamespace(
        api_mode="anthropic_messages", base_url="", _turn_user_context=turn_context,
        _needs_thinking_reasoning_pad=lambda: False,
        _should_sanitize_tool_calls=lambda: False,
        _sanitize_tool_calls_for_strict_api=lambda m: m,
    )


def _api_text(api_messages, i):
    return api_messages[i]["content"]


def test_legacy_user_message_uses_content():
    from agent.conversation_loop import build_api_messages
    messages = [{"role": "user", "content": "old"}, {"role": "assistant", "content": "a"},
                {"role": "user", "content": "new"}]
    out = build_api_messages(_agent(), messages, 2, [])
    assert _api_text(out, 0) == "old"
    assert all("api_content" not in m and "api_blocks" not in m for m in out)


def test_loop_sends_same_bytes_next_turn():
    from agent.conversation_loop import build_api_messages
    agent = _agent(VOICE)
    messages = [{"role": "user", "content": "q1"}]
    first = build_api_messages(agent, messages, 0, [BRIEF_A])
    assert _api_text(first, 0) == "q1\n\n" + BRIEF_A + "\n\n" + VOICE
    messages += [{"role": "assistant", "content": "a1"}, {"role": "user", "content": "q2"}]
    second = build_api_messages(agent, messages, 2, [BRIEF_B])
    assert _api_text(second, 0) == _api_text(first, 0)
    # The unchanged voice rules are not repeated; the changed brief is.
    assert _api_text(second, 2) == "q2\n\n" + BRIEF_B


def test_current_turn_is_computed_once():
    from agent.conversation_loop import build_api_messages
    agent = _agent()
    messages = [{"role": "user", "content": "q1"}]
    first = build_api_messages(agent, messages, 0, [BRIEF_A])
    again = build_api_messages(agent, messages, 0, [BRIEF_B])
    assert _api_text(again, 0) == _api_text(first, 0)


def test_turn_without_additions_stays_plain():
    from agent.conversation_loop import build_api_messages
    messages = [{"role": "user", "content": "q1"}]
    out = build_api_messages(_agent(), messages, 0, [])
    assert _api_text(out, 0) == "q1" and "api_content" not in messages[0]
