"""Claude Code (local-CLI subscription) onboarding flow.

Regression coverage for the bug where webui/api/oauth.py collapsed the
"claude-code" provider into the Anthropic-API path: the subscription token got
linked into pool["anthropic"] and the active provider stayed "anthropic", so
chat hit api.anthropic.com → 400 "You're out of extra usage".

The fix routes "claude-code" to its own flow that (a) reads the host login
state via auth.get_external_process_provider_status and (b) persists a sticky
``@claude-code:`` default model so provider="claude-code" → ClaudeCodeClient.

These tests patch at the SOURCE module names because oauth.py lazy-imports the
auth/config helpers inside the flow functions (import resolves at call time).
"""

from __future__ import annotations

import pytest


# ── provider normalization no longer folds claude-code into anthropic ────────

def test_claude_code_not_in_anthropic_aliases():
    import api.oauth as oauth

    assert "claude-code" not in oauth._ANTHROPIC_PROVIDER_ALIASES
    # The legitimate Anthropic-API aliases are untouched.
    assert "claude" in oauth._ANTHROPIC_PROVIDER_ALIASES
    assert "anthropic" in oauth._ANTHROPIC_PROVIDER_ALIASES
    # Still an allowed onboarding provider, just routed differently.
    assert "claude-code" in oauth._ALLOWED_ONBOARDING_OAUTH_PROVIDERS


def test_normalize_keeps_claude_code_distinct():
    import api.oauth as oauth

    assert oauth._normalize_onboarding_oauth_provider("claude-code") == "claude-code"
    assert oauth._normalize_onboarding_oauth_provider("claude") == "anthropic"
    assert oauth._normalize_onboarding_oauth_provider("anthropic") == "anthropic"


# ── default-model helper produces a sticky @claude-code: tag ─────────────────

def test_default_model_is_claude_code_tagged():
    import api.oauth as oauth

    model_id = oauth._claude_code_default_model()
    assert model_id.startswith("@claude-code:")
    # The bare id after the prefix must be non-empty.
    assert model_id.split(":", 1)[1].strip()


# ── logged-in: success + sticky default persisted ───────────────────────────

def test_start_logged_in_persists_sticky_default(monkeypatch):
    import api.oauth as oauth
    import jarviscopilot_cli.auth as cli_auth
    import api.config as config

    oauth._OAUTH_FLOWS.clear()

    monkeypatch.setattr(
        cli_auth,
        "get_external_process_provider_status",
        lambda provider: {"logged_in": True, "configured": True},
    )
    calls: list[str] = []
    monkeypatch.setattr(
        config, "set_hermes_default_model", lambda model_id: calls.append(model_id)
    )
    # Never spawn a background worker in the logged-in path; assert it isn't.
    monkeypatch.setattr(
        oauth,
        "_spawn_claude_code_login_worker",
        lambda flow_id: (_ for _ in ()).throw(AssertionError("worker spawned")),
    )

    payload = oauth.start_onboarding_oauth_flow({"provider": "claude-code"})

    assert payload["provider"] == "claude-code"
    assert payload["status"] == "success"
    assert len(calls) == 1
    assert calls[0].startswith("@claude-code:")


# ── not-logged-in: pending flow with action_required guidance ────────────────

def test_start_not_logged_in_returns_pending(monkeypatch):
    import api.oauth as oauth
    import jarviscopilot_cli.auth as cli_auth

    oauth._OAUTH_FLOWS.clear()

    monkeypatch.setattr(
        cli_auth,
        "get_external_process_provider_status",
        lambda provider: {"logged_in": False, "configured": True},
    )
    # Don't actually start a polling thread.
    monkeypatch.setattr(oauth, "_spawn_claude_code_login_worker", lambda flow_id: None)

    payload = oauth.start_onboarding_oauth_flow({"provider": "claude-code"})

    assert payload["provider"] == "claude-code"
    assert payload["status"] == "pending"
    assert "action_required" in payload
    assert "claude login" in payload["action_required"] or "claude setup-token" in payload["action_required"]
    assert payload["flow_id"] in oauth._OAUTH_FLOWS


# ── setup_token path: token is stored, then success when logged in ───────────

def test_start_with_setup_token_stores_and_succeeds(monkeypatch):
    import api.oauth as oauth
    import jarviscopilot_cli.auth as cli_auth
    import api.config as config

    oauth._OAUTH_FLOWS.clear()

    stored: list[str] = []
    monkeypatch.setattr(
        cli_auth,
        "store_claude_code_setup_token",
        lambda token: stored.append(token),
    )
    # A stored setup-token counts as logged-in.
    monkeypatch.setattr(
        cli_auth,
        "get_external_process_provider_status",
        lambda provider: {"logged_in": True, "has_setup_token": True},
    )
    monkeypatch.setattr(config, "set_hermes_default_model", lambda model_id: None)
    monkeypatch.setattr(
        oauth,
        "_spawn_claude_code_login_worker",
        lambda flow_id: (_ for _ in ()).throw(AssertionError("worker spawned")),
    )

    token = "sk-ant-oat01-xxx"
    payload = oauth.start_onboarding_oauth_flow(
        {"provider": "claude-code", "setup_token": token}
    )

    assert stored == [token]
    assert payload["provider"] == "claude-code"
    assert payload["status"] == "success"


# ── bad setup_token: store raises AuthError → error payload ───────────────────

def test_start_with_bad_setup_token_returns_error(monkeypatch):
    import api.oauth as oauth
    import jarviscopilot_cli.auth as cli_auth

    oauth._OAUTH_FLOWS.clear()

    def _raise(token):
        raise cli_auth.AuthError(
            "That doesn't look like a Claude Code setup-token.",
            provider="claude-code",
            code="invalid_token",
        )

    monkeypatch.setattr(cli_auth, "store_claude_code_setup_token", _raise)
    # If reached (it must not be), make logged_in True so we can prove the error
    # short-circuits before the login check.
    monkeypatch.setattr(
        cli_auth,
        "get_external_process_provider_status",
        lambda provider: (_ for _ in ()).throw(AssertionError("login checked after bad token")),
    )

    payload = oauth.start_onboarding_oauth_flow(
        {"provider": "claude-code", "setup_token": "not-a-token"}
    )

    assert payload["status"] == "error"
    assert payload["provider"] == "claude-code"
    assert payload["ok"] is False
    assert "setup-token" in payload["error"]


# ── poll/cancel route a claude-code flow by its own provider ─────────────────

def test_poll_and_cancel_handle_claude_code_flow(monkeypatch):
    import api.oauth as oauth
    import jarviscopilot_cli.auth as cli_auth

    oauth._OAUTH_FLOWS.clear()
    monkeypatch.setattr(
        cli_auth,
        "get_external_process_provider_status",
        lambda provider: {"logged_in": False},
    )
    monkeypatch.setattr(oauth, "_spawn_claude_code_login_worker", lambda flow_id: None)

    start = oauth.start_onboarding_oauth_flow({"provider": "claude-code"})
    fid = start["flow_id"]

    polled = oauth.poll_onboarding_oauth_flow(fid)
    assert polled["provider"] == "claude-code"
    assert polled["status"] == "pending"

    cancelled = oauth.cancel_onboarding_oauth_flow(
        {"flow_id": fid, "provider": "claude-code"}
    )
    assert cancelled["status"] == "cancelled"
    # The flow's own provider drives the status payload even though the
    # requested-provider label maps unknown→openai-codex.
    assert cancelled["provider"] == "claude-code"
