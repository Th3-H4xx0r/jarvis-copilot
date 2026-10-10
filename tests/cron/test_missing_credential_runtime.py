"""Cron: a missing credential fails the job with the message — no fallback provider runs it."""

from unittest.mock import MagicMock, patch

import pytest

from agent.error_classifier import MISSING_ANTHROPIC_API_KEY, NO_CLAUDE_ACCOUNT
from cron.scheduler import run_job


@pytest.mark.parametrize(
    "message",
    [
        f"{MISSING_ANTHROPIC_API_KEY}. Add ANTHROPIC_API_KEY in Settings.",
        f"{NO_CLAUDE_ACCOUNT}. Sign in with `claude /login` on the server.",
    ],
)
def test_missing_credential_fails_job_without_fallback(tmp_path, message):
    from jarviscopilot_cli.auth import AuthError

    (tmp_path / "config.yaml").write_text(
        "model:\n  provider: anthropic-api\n  default: claude-sonnet-5-5\n"
        "fallback_model:\n  provider: openrouter\n  model: openai/gpt-5\n"
    )
    calls = []

    def _resolve(**kwargs):
        calls.append(kwargs)
        if len(calls) == 1:
            raise AuthError(message)
        return {
            "api_key": "fallback-key",
            "base_url": "https://openrouter.ai/api/v1",
            "provider": "openrouter",
            "api_mode": "chat_completions",
        }

    job = {"id": "missing-cred", "name": "missing-cred", "prompt": "hello"}
    with patch("cron.scheduler._hermes_home", tmp_path), \
         patch("cron.scheduler._get_hermes_home", return_value=tmp_path), \
         patch("cron.scheduler._resolve_origin", return_value=None), \
         patch("dotenv.load_dotenv"), \
         patch("jarviscopilot_state.SessionDB", return_value=MagicMock()), \
         patch("jarviscopilot_cli.runtime_provider.resolve_runtime_provider", side_effect=_resolve), \
         patch("run_agent.AIAgent") as agent_cls:
        success, _output, final_response, error = run_job(job)

    assert success is False
    assert message in (error or "")
    assert len(calls) == 1, "the fallback provider must not be resolved"
    agent_cls.assert_not_called()
