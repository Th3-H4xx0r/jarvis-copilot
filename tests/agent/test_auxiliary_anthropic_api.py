"""Aux tasks (titles, compression, vision, fallback) on `anthropic-api` use the API key only."""

from unittest.mock import patch

from agent import auxiliary_client as aux

KEY = "sk-ant-usr01-" + "k" * 40
SUBSCRIPTION = "sk-ant-oat01-" + "o" * 40


def _clear(monkeypatch):
    for var in ("ANTHROPIC_API_KEY", "ANTHROPIC_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"):
        monkeypatch.delenv(var, raising=False)


def test_builds_an_x_api_key_client_from_the_key(monkeypatch):
    _clear(monkeypatch)
    monkeypatch.setenv("ANTHROPIC_API_KEY", KEY)
    monkeypatch.setenv("ANTHROPIC_TOKEN", SUBSCRIPTION)

    with patch("agent.anthropic_adapter.build_anthropic_client") as build:
        client, model = aux.resolve_provider_client("anthropic-api", "claude-haiku-4-5")

    assert client is not None and model
    args, kwargs = build.call_args
    assert args[0] == KEY
    assert kwargs.get("force_api_key") is True
    assert client.api_key == KEY


def test_no_key_means_no_client_even_with_a_subscription(monkeypatch):
    _clear(monkeypatch)
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", SUBSCRIPTION)

    with patch("agent.anthropic_adapter.build_anthropic_client") as build:
        client, _ = aux.resolve_provider_client("anthropic-api", "claude-haiku-4-5")

    assert client is None
    build.assert_not_called()
