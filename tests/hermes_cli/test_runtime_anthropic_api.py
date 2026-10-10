"""Runtime resolution for `anthropic-api`: the API key or a clear error — never a Claude subscription token."""

import pytest

from jarviscopilot_cli import runtime_provider as rp
from jarviscopilot_cli.auth import AuthError

KEY = "sk-ant-usr01-" + "k" * 40
SUBSCRIPTION = "sk-ant-oat01-" + "o" * 40


@pytest.fixture
def anthropic_api(monkeypatch):
    """Configured provider = anthropic-api; the credential pool must never be consulted."""
    monkeypatch.setattr(rp, "_get_model_config", lambda: {"provider": "anthropic-api"})

    def _no_pool(provider):
        raise AssertionError(f"credential pool consulted for {provider}")

    monkeypatch.setattr(rp, "load_pool", _no_pool)
    for var in ("ANTHROPIC_API_KEY", "ANTHROPIC_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"):
        monkeypatch.delenv(var, raising=False)
    return monkeypatch


def test_uses_the_api_key_even_with_subscription_tokens_present(anthropic_api):
    anthropic_api.setenv("ANTHROPIC_API_KEY", f"  {KEY}\n")
    anthropic_api.setenv("ANTHROPIC_TOKEN", SUBSCRIPTION)
    anthropic_api.setenv("CLAUDE_CODE_OAUTH_TOKEN", SUBSCRIPTION)

    rt = rp.resolve_runtime_provider(requested="anthropic-api")

    assert rt["provider"] == "anthropic-api"
    assert rt["api_mode"] == "anthropic_messages"
    assert rt["api_key"] == KEY
    assert rt["base_url"] == "https://api.anthropic.com"


def test_no_key_is_a_clear_error_not_the_subscription(anthropic_api):
    anthropic_api.setenv("CLAUDE_CODE_OAUTH_TOKEN", SUBSCRIPTION)

    with pytest.raises(AuthError, match="No Anthropic API key configured"):
        rp.resolve_runtime_provider(requested="anthropic-api")


def test_a_subscription_token_in_the_key_slot_is_refused(anthropic_api):
    anthropic_api.setenv("ANTHROPIC_API_KEY", SUBSCRIPTION)

    with pytest.raises(AuthError, match="No Anthropic API key configured"):
        rp.resolve_runtime_provider(requested="anthropic-api")


def test_explicit_key_and_base_url_win(anthropic_api):
    rt = rp.resolve_runtime_provider(
        requested="anthropic-api", explicit_api_key=KEY,
        explicit_base_url="https://proxy.example.com/",
    )
    assert rt["api_key"] == KEY
    assert rt["base_url"] == "https://proxy.example.com"
    assert rt["api_mode"] == "anthropic_messages"


def test_config_base_url_applies_only_when_anthropic_api_is_configured(monkeypatch, anthropic_api):
    anthropic_api.setenv("ANTHROPIC_API_KEY", KEY)
    monkeypatch.setattr(rp, "_get_model_config",
                        lambda: {"provider": "openai-codex", "base_url": "https://chatgpt.com/backend-api/codex"})

    rt = rp.resolve_runtime_provider(requested="anthropic-api")

    assert rt["base_url"] == "https://api.anthropic.com"
