"""Gateway: a missing credential is reported, never swapped for the fallback provider.

Other AuthErrors (expired token, revoked key) still try the fallback chain (#7230).
"""

from unittest.mock import patch

import pytest

from agent.error_classifier import MISSING_ANTHROPIC_API_KEY, NO_CLAUDE_ACCOUNT

_FALLBACK_RUNTIME = {
    "api_key": "fallback-key",
    "base_url": "https://openrouter.ai/api/v1",
    "provider": "openrouter",
    "api_mode": "chat_completions",
    "command": None,
    "args": None,
    "credential_pool": None,
}


@pytest.mark.parametrize(
    "message",
    [
        f"{MISSING_ANTHROPIC_API_KEY}. Add ANTHROPIC_API_KEY in Settings.",
        f"{NO_CLAUDE_ACCOUNT}. Sign in with `claude /login` on the server.",
    ],
)
def test_missing_credential_raises_instead_of_using_fallback(tmp_path, monkeypatch, message):
    from jarviscopilot_cli.auth import AuthError

    (tmp_path / "config.yaml").write_text(
        "model:\n  provider: anthropic-api\n"
        "fallback_model:\n  provider: openrouter\n  model: openai/gpt-5\n"
    )
    monkeypatch.setattr("gateway.run._hermes_home", tmp_path)
    calls = []

    def _resolve(**kwargs):
        calls.append(kwargs)
        if len(calls) == 1:
            raise AuthError(message)
        return dict(_FALLBACK_RUNTIME)

    with patch("jarviscopilot_cli.runtime_provider.resolve_runtime_provider", side_effect=_resolve):
        from gateway.run import _resolve_runtime_agent_kwargs

        with pytest.raises(RuntimeError) as excinfo:
            _resolve_runtime_agent_kwargs()

    assert message in str(excinfo.value)
    assert len(calls) == 1, "the fallback provider must not be resolved"
