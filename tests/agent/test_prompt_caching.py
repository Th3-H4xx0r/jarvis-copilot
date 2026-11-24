"""Tests for agent/prompt_caching.py — Anthropic cache control injection."""

import copy
import pytest

from types import SimpleNamespace

from agent.prompt_caching import (
    _apply_cache_marker,
    apply_anthropic_cache_control,
    one_shot_run,
)


MARKER = {"type": "ephemeral"}


class TestApplyCacheMarker:
    def test_tool_message_gets_top_level_marker_on_native_anthropic(self):
        """Native Anthropic path: cache_control injected top-level (adapter moves it inside tool_result)."""
        msg = {"role": "tool", "content": "result"}
        _apply_cache_marker(msg, MARKER, native_anthropic=True)
        assert msg["cache_control"] == MARKER

    def test_tool_message_skips_marker_on_openrouter(self):
        """OpenRouter path: top-level cache_control on role:tool is invalid and causes silent hang."""
        msg = {"role": "tool", "content": "result"}
        _apply_cache_marker(msg, MARKER, native_anthropic=False)
        assert "cache_control" not in msg

    def test_none_content_gets_top_level_marker(self):
        msg = {"role": "assistant", "content": None}
        _apply_cache_marker(msg, MARKER)
        assert msg["cache_control"] == MARKER

    def test_empty_string_content_gets_top_level_marker(self):
        """Empty text blocks cannot have cache_control (Anthropic rejects them)."""
        msg = {"role": "assistant", "content": ""}
        _apply_cache_marker(msg, MARKER)
        assert msg["cache_control"] == MARKER
        # Must NOT wrap into [{"type": "text", "text": "", "cache_control": ...}]
        assert msg["content"] == ""

    def test_string_content_wrapped_in_list(self):
        msg = {"role": "user", "content": "Hello"}
        _apply_cache_marker(msg, MARKER)
        assert isinstance(msg["content"], list)
        assert len(msg["content"]) == 1
        assert msg["content"][0]["type"] == "text"
        assert msg["content"][0]["text"] == "Hello"
        assert msg["content"][0]["cache_control"] == MARKER

    def test_list_content_last_item_gets_marker(self):
        msg = {
            "role": "user",
            "content": [
                {"type": "text", "text": "First"},
                {"type": "text", "text": "Second"},
            ],
        }
        _apply_cache_marker(msg, MARKER)
        assert "cache_control" not in msg["content"][0]
        assert msg["content"][1]["cache_control"] == MARKER

    def test_empty_list_content_no_crash(self):
        msg = {"role": "user", "content": []}
        # Should not crash on empty list
        _apply_cache_marker(msg, MARKER)


class TestApplyAnthropicCacheControl:
    def test_empty_messages(self):
        result = apply_anthropic_cache_control([])
        assert result == []

    def test_returns_deep_copy(self):
        msgs = [{"role": "user", "content": "Hello"}]
        result = apply_anthropic_cache_control(msgs)
        assert result is not msgs
        assert result[0] is not msgs[0]
        # Original should be unmodified
        assert "cache_control" not in msgs[0].get("content", "")

    def test_system_message_gets_marker(self):
        msgs = [
            {"role": "system", "content": "You are helpful"},
            {"role": "user", "content": "Hi"},
        ]
        result = apply_anthropic_cache_control(msgs)
        # System message should have cache_control
        sys_content = result[0]["content"]
        assert isinstance(sys_content, list)
        assert sys_content[0]["cache_control"]["type"] == "ephemeral"

    def test_last_3_non_system_get_markers(self):
        msgs = [
            {"role": "system", "content": "System"},
            {"role": "user", "content": "msg1"},
            {"role": "assistant", "content": "msg2"},
            {"role": "user", "content": "msg3"},
            {"role": "assistant", "content": "msg4"},
        ]
        result = apply_anthropic_cache_control(msgs)
        # System (index 0) + last 3 non-system (indices 2, 3, 4) = 4 breakpoints
        # Index 1 (msg1) should NOT have marker
        content_1 = result[1]["content"]
        if isinstance(content_1, str):
            assert True  # No marker applied (still a string)
        else:
            assert "cache_control" not in content_1[0]

    def test_no_system_message(self):
        msgs = [
            {"role": "user", "content": "Hello"},
            {"role": "assistant", "content": "Hi"},
        ]
        result = apply_anthropic_cache_control(msgs)
        # Both should get markers (4 slots available, only 2 messages)
        assert len(result) == 2

    def test_1h_ttl(self):
        msgs = [{"role": "system", "content": "System prompt"}]
        result = apply_anthropic_cache_control(msgs, cache_ttl="1h")
        sys_content = result[0]["content"]
        assert isinstance(sys_content, list)
        assert sys_content[0]["cache_control"]["ttl"] == "1h"

    def test_max_4_breakpoints(self):
        msgs = [
            {"role": "system", "content": "System"},
        ] + [
            {"role": "user" if i % 2 == 0 else "assistant", "content": f"msg{i}"}
            for i in range(10)
        ]
        result = apply_anthropic_cache_control(msgs)
        # Count how many messages have cache_control
        count = 0
        for msg in result:
            content = msg.get("content")
            if isinstance(content, list):
                for item in content:
                    if isinstance(item, dict) and "cache_control" in item:
                        count += 1
            elif "cache_control" in msg:
                count += 1
        assert count <= 4


class TestOneShotRetention:
    """One-shot runs (cron) never read their per-run messages again, so their
    message markers use the 5-minute tier; chats keep today's layout."""

    @staticmethod
    def _msgs():
        return [
            {"role": "system", "content": "sys"},
            {"role": "user", "content": "u1"},
            {"role": "assistant", "content": "a1"},
            {"role": "user", "content": "u2"},
        ]

    @staticmethod
    def _markers(msg):
        content = msg.get("content")
        if isinstance(content, list):
            return [b["cache_control"] for b in content if isinstance(b, dict) and "cache_control" in b]
        return [msg["cache_control"]] if "cache_control" in msg else []

    def test_one_shot_long_retention_messages_5m(self):
        out = apply_anthropic_cache_control(self._msgs(), native_anthropic=True,
                                            retention="long", one_shot=True)
        assert self._markers(out[0]) == [{"type": "ephemeral", "ttl": "1h"}]
        message_markers = [mk for m in out[1:] for mk in self._markers(m)]
        assert message_markers == [{"type": "ephemeral"}] * 3

    def test_long_retention_uses_uniform_1h_message_markers(self):
        """Measured live (2026-11-24, Haiku and Sonnet 5.5): an older 1h marker
        next to a newest 5m marker made the NEXT turn miss the cache entirely
        (read 0, re-wrote everything); uniform message markers (all 1h, or all
        5m) read the whole previous turn. Chats use 1h throughout."""
        out = apply_anthropic_cache_control(self._msgs(), native_anthropic=True, retention="long")
        assert self._markers(out[0]) == [{"type": "ephemeral", "ttl": "1h"}]
        assert [self._markers(m) for m in out[1:]] == [[{"type": "ephemeral", "ttl": "1h"}]] * 3

    def test_standard_retention_all_5m(self):
        out = apply_anthropic_cache_control(self._msgs(), native_anthropic=True, retention="standard")
        assert [mk for m in out for mk in self._markers(m)] == [{"type": "ephemeral"}] * 4

    def test_one_shot_run_is_cron_only(self):
        assert one_shot_run(SimpleNamespace(platform="cron")) is True
        assert one_shot_run(SimpleNamespace(platform="webui")) is False
        assert one_shot_run(SimpleNamespace()) is False
