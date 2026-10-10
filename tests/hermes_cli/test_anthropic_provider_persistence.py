"""Tests for Anthropic credential persistence helpers."""

from jarviscopilot_cli.config import load_env


def test_save_anthropic_oauth_token_uses_token_slot_and_keeps_the_api_key(tmp_path, monkeypatch):
    # The API key belongs to the anthropic-api provider — a Claude sign-in must not delete it.
    home = tmp_path / "jarviscopilot"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))

    from jarviscopilot_cli.config import save_anthropic_oauth_token, save_env_value

    save_env_value("ANTHROPIC_API_KEY", "sk-ant-api03-key")
    save_anthropic_oauth_token("sk-ant-oat01-test-token")

    env_vars = load_env()
    assert env_vars["ANTHROPIC_TOKEN"] == "sk-ant-oat01-test-token"
    assert env_vars["ANTHROPIC_API_KEY"] == "sk-ant-api03-key"


def test_use_anthropic_claude_code_credentials_clears_the_token_and_keeps_the_api_key(tmp_path, monkeypatch):
    home = tmp_path / "jarviscopilot"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))

    from jarviscopilot_cli.config import (
        save_anthropic_oauth_token,
        save_env_value,
        use_anthropic_claude_code_credentials,
    )

    save_env_value("ANTHROPIC_API_KEY", "sk-ant-api03-key")
    save_anthropic_oauth_token("sk-ant-oat01-token")
    use_anthropic_claude_code_credentials()

    env_vars = load_env()
    assert env_vars["ANTHROPIC_TOKEN"] == ""
    assert env_vars["ANTHROPIC_API_KEY"] == "sk-ant-api03-key"


def test_save_anthropic_api_key_uses_api_key_slot_and_clears_token(tmp_path, monkeypatch):
    home = tmp_path / "jarviscopilot"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))

    from jarviscopilot_cli.config import save_anthropic_api_key

    save_anthropic_api_key("sk-ant-api03-key")

    env_vars = load_env()
    assert env_vars["ANTHROPIC_API_KEY"] == "sk-ant-api03-key"
    assert env_vars["ANTHROPIC_TOKEN"] == ""
