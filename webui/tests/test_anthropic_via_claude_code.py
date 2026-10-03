"""Anthropic picks run on the Claude Code CLI.

The direct Anthropic API answers "You're out of extra usage" (HTTP 400) for a
subscription account, while the same account's `claude` CLI works. A picker
row like ``@anthropic:claude-sonnet-5-5`` must therefore run through the
claude-code provider whenever the CLI is installed — in chat and in voice,
which both build their agent from ``resolve_model_provider``.
"""

import api.config as cfg_mod
from api.config import (
    model_with_provider_context,
    resolve_model_provider,
    route_anthropic_via_claude_code,
)


def test_anthropic_pick_runs_on_claude_code_when_cli_installed(monkeypatch):
    monkeypatch.setattr(cfg_mod, "_claude_cli_installed", lambda: True)
    picked = model_with_provider_context("@anthropic:claude-sonnet-5-5", "anthropic")
    model, provider, base_url = route_anthropic_via_claude_code(*resolve_model_provider(picked))
    assert model == "claude-sonnet-5-5"
    assert provider == "claude-code"
    assert not (base_url or "").startswith("https://api.anthropic.com")


def test_anthropic_pick_stays_on_the_api_without_the_cli(monkeypatch):
    monkeypatch.setattr(cfg_mod, "_claude_cli_installed", lambda: False)
    assert route_anthropic_via_claude_code(
        "claude-sonnet-5-5", "anthropic", "https://api.anthropic.com"
    ) == ("claude-sonnet-5-5", "anthropic", "https://api.anthropic.com")


def test_other_providers_are_untouched(monkeypatch):
    monkeypatch.setattr(cfg_mod, "_claude_cli_installed", lambda: True)
    assert route_anthropic_via_claude_code(
        "gemma4:31b", "ollama-cloud", "https://ollama.com/v1"
    ) == ("gemma4:31b", "ollama-cloud", "https://ollama.com/v1")
