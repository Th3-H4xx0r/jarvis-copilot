"""A missing credential ends the turn with the error — no fallback answers instead.

"No Anthropic API key configured" / "No Claude account connected" mean the user
has to set something up.  Retrying, rotating pooled credentials or switching to a
fallback model would hide that, so the conversation loop must stop at once.
"""

from unittest.mock import MagicMock, patch

import pytest

from agent.error_classifier import MISSING_ANTHROPIC_API_KEY, NO_CLAUDE_ACCOUNT
from jarviscopilot_cli.auth import AuthError


def _tool_defs(*names):
    return [
        {
            "type": "function",
            "function": {
                "name": n,
                "description": f"{n} tool",
                "parameters": {"type": "object", "properties": {}},
            },
        }
        for n in names
    ]


@pytest.fixture()
def agent():
    with (
        patch("run_agent.get_tool_definitions", return_value=_tool_defs("web_search")),
        patch("run_agent.check_toolset_requirements", return_value={}),
        patch("run_agent.OpenAI"),
    ):
        from run_agent import AIAgent

        a = AIAgent(
            api_key="test-key-1234567890",
            base_url="https://openrouter.ai/api/v1",
            quiet_mode=True,
            skip_context_files=True,
            skip_memory=True,
        )
    a.client = MagicMock()
    a._cached_system_prompt = "You are helpful."
    a._use_prompt_caching = False
    a.tool_delay = 0
    a.compression_enabled = False
    a.save_trajectories = False
    # A fallback is configured — it must still never be used.
    a._fallback_chain = [{"provider": "openrouter", "model": "openai/gpt-5"}]
    a._fallback_index = 0
    a._fallback_activated = False
    return a


@pytest.mark.parametrize(
    "message",
    [
        f"{MISSING_ANTHROPIC_API_KEY}. Add ANTHROPIC_API_KEY in Settings.",
        f"{NO_CLAUDE_ACCOUNT}. Sign in with `claude /login` on the server.",
    ],
)
def test_missing_credential_fails_turn_without_fallback(agent, message):
    agent.client.chat.completions.create.side_effect = AuthError(message)

    with (
        patch.object(agent, "_persist_session"),
        patch.object(agent, "_save_trajectory"),
        patch.object(agent, "_cleanup_task_resources"),
        # Both report "nothing recovered" so a regression fails fast
        # instead of looping; the assertions below check they weren't asked.
        patch.object(agent, "_try_activate_fallback", return_value=False) as fallback,
        patch.object(
            agent, "_recover_with_credential_pool", return_value=(False, False)
        ) as pool,
    ):
        result = agent.run_conversation("hello")

    fallback.assert_not_called()
    pool.assert_not_called()
    assert result["failed"] is True
    assert result["completed"] is False
    assert message in result["error"]
    # Surfaces read _last_error first — a stale one must not shadow this.
    assert message in agent._last_error
    # One attempt only — no retries burn time before the user sees the error.
    assert agent.client.chat.completions.create.call_count == 1


class _Unauthorized(Exception):
    status_code = 401


def test_a_rejected_api_key_on_anthropic_api_is_shown_not_answered_by_a_fallback(agent):
    """An invalid/revoked key isn't temporary: the user must see it, no fallback model."""
    agent.provider = "anthropic-api"
    agent.client.chat.completions.create.side_effect = _Unauthorized("invalid x-api-key")

    with (
        patch.object(agent, "_persist_session"),
        patch.object(agent, "_save_trajectory"),
        patch.object(agent, "_cleanup_task_resources"),
        patch.object(agent, "_try_activate_fallback", return_value=False) as fallback,
    ):
        result = agent.run_conversation("hello")

    fallback.assert_not_called()
    assert result["failed"] is True
    assert MISSING_ANTHROPIC_API_KEY in result["error"]
    assert "rejected" in result["error"]


def test_other_auth_errors_still_try_the_fallback(agent):
    """Only the two missing-credential errors skip the fallback."""
    agent.client.chat.completions.create.side_effect = _Unauthorized("invalid x-api-key")
    calls = {"n": 0}

    def _no_more_fallbacks():
        calls["n"] += 1
        return False

    with (
        patch.object(agent, "_persist_session"),
        patch.object(agent, "_save_trajectory"),
        patch.object(agent, "_cleanup_task_resources"),
        patch.object(agent, "_try_activate_fallback", side_effect=_no_more_fallbacks),
    ):
        result = agent.run_conversation("hello")

    assert calls["n"] >= 1
    assert result["failed"] is True
