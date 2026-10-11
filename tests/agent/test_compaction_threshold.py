"""The auto-compact trigger is a percentage of the active model's real window.

Regression for "it compacts at 64K even on a 1M model": a hidden 64,000-token
default cap (``compression.max_context_tokens``) clamped every model, so a
large system prompt alone tripped compaction on the first tool round, and the
"compaction" had nothing it could remove.
"""

from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from agent.context_compressor import (
    ContextCompressor,
    compute_threshold_tokens,
    normalize_threshold_percent,
)
from agent.model_metadata import DEFAULT_FALLBACK_CONTEXT, MINIMUM_CONTEXT_LENGTH


def _compressor(context_length, **kwargs):
    kwargs.setdefault("quiet_mode", True)
    with patch("agent.context_compressor.get_model_context_length", return_value=context_length):
        return ContextCompressor(model="m", **kwargs)


class TestComputeThreshold:
    def test_1m_window_at_50_percent_compacts_at_500k(self):
        assert compute_threshold_tokens(1_000_000, 0.50) == 500_000

    def test_scales_with_the_window(self):
        assert compute_threshold_tokens(200_000, 0.50) == 100_000
        assert compute_threshold_tokens(1_000_000, 0.75) == 750_000

    def test_small_window_keeps_the_minimum_floor(self):
        # 50% of 128K is 64K; 50% of 100K would be 50K but the floor holds.
        assert compute_threshold_tokens(128_000, 0.50) == MINIMUM_CONTEXT_LENGTH
        assert compute_threshold_tokens(100_000, 0.50) == MINIMUM_CONTEXT_LENGTH

    def test_never_above_95_percent_of_the_window(self):
        # A 64K model: the floor would be 100% of the window, leaving no room
        # for the reply before compaction runs.
        assert compute_threshold_tokens(64_000, 0.50) == int(64_000 * 0.95)
        assert compute_threshold_tokens(1_000_000, 1.0) == 950_000

    def test_unknown_window_uses_the_fallback_not_64k(self):
        assert compute_threshold_tokens(0, 0.50) == int(DEFAULT_FALLBACK_CONTEXT * 0.50)
        assert compute_threshold_tokens(None, 0.50) == int(DEFAULT_FALLBACK_CONTEXT * 0.50)

    def test_token_cap_lowers_but_never_raises(self):
        assert compute_threshold_tokens(1_000_000, 0.50, 200_000) == 200_000
        assert compute_threshold_tokens(200_000, 0.50, 500_000) == 100_000
        # 0 / None = no cap.
        assert compute_threshold_tokens(1_000_000, 0.50, 0) == 500_000
        assert compute_threshold_tokens(1_000_000, 0.50, None) == 500_000


class TestNormalizePercent:
    @pytest.mark.parametrize("raw,expected", [
        (0.5, 0.5), (0.75, 0.75), (75, 0.75), ("60", 0.60), ("0.3", 0.3),
        (0, 0.10), (0.01, 0.10), (1.0, 0.95), (100, 0.95), (250, 0.95),
        ("abc", 0.50), (None, 0.50), (float("nan"), 0.50),
    ])
    def test_band_and_forms(self, raw, expected):
        assert normalize_threshold_percent(raw) == pytest.approx(expected)


class TestCompressorTrigger:
    def test_large_system_prompt_alone_does_not_compact_on_1m_model(self):
        c = _compressor(1_000_000, threshold_percent=0.50)
        # ~60K system prompt + tools + one short exchange.
        assert c.should_compress(66_000) is False
        assert c.threshold_tokens == 500_000

    def test_no_hidden_absolute_cap_by_default(self):
        c = _compressor(1_000_000, threshold_percent=0.75)
        assert c.threshold_tokens == 750_000

    def test_percent_given_as_whole_number_is_understood(self):
        c = _compressor(1_000_000, threshold_percent=75)
        assert c.threshold_percent == pytest.approx(0.75)
        assert c.threshold_tokens == 750_000

    def test_model_switch_recomputes_from_the_new_window(self):
        c = _compressor(1_000_000, threshold_percent=0.50)
        c.update_model("small", context_length=200_000)
        assert c.threshold_tokens == 100_000
        c.update_model("big", context_length=1_000_000)
        assert c.threshold_tokens == 500_000

    def test_set_trigger_applies_in_place(self):
        c = _compressor(1_000_000, threshold_percent=0.50, summary_target_ratio=0.20)
        c.set_trigger(threshold_percent=0.80, max_threshold_tokens=0)
        assert c.threshold_tokens == 800_000
        assert c.tail_token_budget == int(800_000 * 0.20)
        c.set_trigger(threshold_percent=0.80, max_threshold_tokens=300_000)
        assert c.threshold_tokens == 300_000
        assert c.max_threshold_tokens == 300_000
        c.set_trigger(threshold_percent=0.80, max_threshold_tokens=0)
        assert c.max_threshold_tokens is None
        assert c.threshold_tokens == 800_000


class TestNothingToCompress:
    def _msgs(self, n):
        return [{"role": "user" if i % 2 == 0 else "assistant", "content": f"m{i}"}
                for i in range(n)]

    def test_short_session_has_nothing_to_compress(self):
        """Matches compress(): it refuses <= head + 4 messages."""
        c = _compressor(200_000, protect_first_n=3)
        assert c.has_content_to_compress(self._msgs(5)) is False
        assert c.compress(self._msgs(5)) == self._msgs(5)

    def test_long_session_has_content(self):
        c = _compressor(200_000, protect_first_n=3)
        assert c.has_content_to_compress(self._msgs(40)) is True


class TestAutoCompressDue:
    """The post-response trigger: threshold reached AND something to compact."""

    def _agent(self, *, over=True, content=True, enabled=True):
        compressor = MagicMock()
        compressor.should_compress.return_value = over
        compressor.has_content_to_compress.return_value = content
        return SimpleNamespace(context_compressor=compressor, compression_enabled=enabled)

    def test_due_when_over_threshold_with_content(self):
        from agent.conversation_loop import _auto_compress_due
        assert _auto_compress_due(self._agent(), 600_000, [{}] * 30) is True

    def test_not_due_when_only_the_protected_head_and_tail_exist(self):
        from agent.conversation_loop import _auto_compress_due
        assert _auto_compress_due(self._agent(content=False), 70_000, [{}] * 5) is False

    def test_not_due_below_threshold_or_disabled(self):
        from agent.conversation_loop import _auto_compress_due
        assert _auto_compress_due(self._agent(over=False), 10, [{}] * 30) is False
        assert _auto_compress_due(self._agent(enabled=False), 600_000, [{}] * 30) is False

    def test_engine_without_the_check_still_compresses(self):
        from agent.conversation_loop import _auto_compress_due
        compressor = SimpleNamespace(should_compress=lambda tokens: True)
        agent = SimpleNamespace(context_compressor=compressor, compression_enabled=True)
        assert _auto_compress_due(agent, 600_000, [{}] * 30) is True


class TestCompressContextNoOp:
    def test_unchanged_messages_do_not_rotate_the_session(self):
        """A compressor that removed nothing must not split the session or
        rebuild the system prompt (that would be a prompt-cache miss)."""
        from agent.conversation_compression import compress_context

        messages = [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "yo"}]
        agent = MagicMock()
        agent.context_compressor = _compressor(200_000)
        agent._compression_feasibility_checked = True
        agent._memory_manager = None
        agent._cached_system_prompt = "SYSTEM"
        agent.session_id = "s1"

        out, prompt = compress_context(agent, messages, "sys")

        assert out is messages
        assert prompt == "SYSTEM"
        agent._invalidate_system_prompt.assert_not_called()
        agent._build_system_prompt.assert_not_called()


def test_agent_built_from_config_has_no_64k_cap():
    """End to end: config with only a percentage → the trigger is pct × window."""
    cfg = {"compression": {"enabled": True, "threshold": 0.75}, "agent": {}}
    with (
        patch("jarviscopilot_cli.config.load_config", return_value=cfg),
        patch("agent.context_compressor.get_model_context_length", return_value=1_000_000),
        patch("agent.model_metadata.get_model_context_length", return_value=1_000_000),
        patch("run_agent.get_tool_definitions", return_value=[]),
        patch("run_agent.check_toolset_requirements", return_value={}),
        patch("run_agent.OpenAI"),
    ):
        from run_agent import AIAgent

        agent = AIAgent(
            model="claude-sonnet-5-5",
            api_key="test-key-1234567890",
            base_url="https://openrouter.ai/api/v1",
            quiet_mode=True,
            skip_context_files=True,
            skip_memory=True,
        )
    assert agent.context_compressor.threshold_tokens == 750_000


def test_agent_honours_an_explicit_token_cap():
    cfg = {"compression": {"threshold": 0.75, "max_context_tokens": 200_000}, "agent": {}}
    with (
        patch("jarviscopilot_cli.config.load_config", return_value=cfg),
        patch("agent.context_compressor.get_model_context_length", return_value=1_000_000),
        patch("agent.model_metadata.get_model_context_length", return_value=1_000_000),
        patch("run_agent.get_tool_definitions", return_value=[]),
        patch("run_agent.check_toolset_requirements", return_value={}),
        patch("run_agent.OpenAI"),
    ):
        from run_agent import AIAgent

        agent = AIAgent(
            model="claude-sonnet-5-5",
            api_key="test-key-1234567890",
            base_url="https://openrouter.ai/api/v1",
            quiet_mode=True,
            skip_context_files=True,
            skip_memory=True,
        )
    assert agent.context_compressor.threshold_tokens == 200_000
