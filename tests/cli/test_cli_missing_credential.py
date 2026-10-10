"""CLI: a missing credential is printed, never swapped for a fallback provider."""

import importlib
import sys
import types

import pytest

from agent.error_classifier import MISSING_ANTHROPIC_API_KEY, NO_CLAUDE_ACCOUNT
from jarviscopilot_cli.auth import AuthError


@pytest.fixture(autouse=True)
def _restore_cli_and_tool_modules():
    prefixes = ("tools", "cli", "run_agent")
    saved = {
        n: m for n, m in sys.modules.items()
        if any(n == p or n.startswith(p + ".") for p in prefixes)
    }
    try:
        yield
    finally:
        for n in list(sys.modules):
            if any(n == p or n.startswith(p + ".") for p in prefixes):
                sys.modules.pop(n, None)
        sys.modules.update(saved)


def _import_cli():
    for name in list(sys.modules):
        if name in ("cli", "run_agent", "tools") or name.startswith("tools."):
            sys.modules.pop(name, None)
    if "firecrawl" not in sys.modules:
        sys.modules["firecrawl"] = types.SimpleNamespace(Firecrawl=object)
    importlib.import_module("prompt_toolkit")
    return importlib.import_module("cli")


@pytest.mark.parametrize(
    "message",
    [
        f"{MISSING_ANTHROPIC_API_KEY}. Add ANTHROPIC_API_KEY in Settings.",
        f"{NO_CLAUDE_ACCOUNT}. Sign in with `claude /login` on the server.",
    ],
)
def test_missing_credential_is_not_swapped_for_fallback(monkeypatch, message):
    cli = _import_cli()
    calls = []

    def _resolve(**kwargs):
        calls.append(kwargs)
        if len(calls) == 1:
            raise AuthError(message)
        return {
            "provider": "openrouter",
            "api_mode": "chat_completions",
            "base_url": "https://openrouter.ai/api/v1",
            "api_key": "fallback-key",
            "source": "env/config",
        }

    printed = []
    monkeypatch.setattr("jarviscopilot_cli.runtime_provider.resolve_runtime_provider", _resolve)
    monkeypatch.setattr("jarviscopilot_cli.runtime_provider.format_runtime_provider_error", lambda exc: str(exc))
    monkeypatch.setattr(cli, "ChatConsole", lambda: types.SimpleNamespace(print=lambda m, *a, **k: printed.append(m)))

    shell = cli.HermesCLI(model="claude-sonnet-5-5", compact=True, max_turns=1)
    shell._fallback_model = [{"provider": "openrouter", "model": "openai/gpt-5"}]

    assert shell._ensure_runtime_credentials() is False
    assert len(calls) == 1, "the fallback provider must not be resolved"
    assert shell.model == "claude-sonnet-5-5"
    assert any(message in str(m) for m in printed)
