"""claude-code uses only the Claude subscription.

`claude auth status` is probed with the same scrubbed env the provider runs
`claude` with (no ANTHROPIC_API_KEY, managed setup-token injected). Connected =
logged in with a subscription auth method ("claude.ai" / "oauth_token") or a
stored setup-token. Not connected → "No Claude account connected".
All subprocess calls are mocked — no real CLI, no network.
"""

import json
import subprocess
from unittest import mock

import pytest

from agent.error_classifier import NO_CLAUDE_ACCOUNT, FailoverReason, classify_api_error
from jarviscopilot_cli import auth as auth_mod

CLAUDE = "/usr/local/bin/claude"


def _cp(stdout="", returncode=0, stderr=""):
    cp = mock.Mock()
    cp.stdout = stdout
    cp.stderr = stderr
    cp.returncode = returncode
    return cp


def _status(logged_in=True, method="claude.ai", sub="max"):
    return json.dumps({"loggedIn": logged_in, "authMethod": method, "subscriptionType": sub})


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    auth_mod._CLAUDE_CODE_LOGIN_CACHE.clear()
    monkeypatch.delenv("HERMES_CLAUDE_CODE_COMMAND", raising=False)
    monkeypatch.delenv("CLAUDE_CLI_PATH", raising=False)
    monkeypatch.delenv("HERMES_CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    monkeypatch.setattr(auth_mod, "has_claude_code_setup_token", lambda: False)
    monkeypatch.setattr(auth_mod, "resolve_claude_code_oauth_token", lambda: None)
    monkeypatch.setattr(auth_mod.shutil, "which", lambda c: CLAUDE if c == "claude" else None)
    yield
    auth_mod._CLAUDE_CODE_LOGIN_CACHE.clear()


def _patch_run(**kwargs):
    return mock.patch.object(auth_mod.subprocess, "run", **kwargs)


# ── auth methods ────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "logged_in, method, connected",
    [
        (True, "claude.ai", True),
        (True, "oauth_token", True),
        (True, "api_key", False),
        (False, "none", False),
    ],
)
def test_auth_method_decides_connected(logged_in, method, connected):
    with _patch_run(return_value=_cp(_status(logged_in, method))):
        state = auth_mod.claude_code_login_state(force=True)
    assert state["connected"] is connected
    assert state["logged_in"] is logged_in
    assert state["auth_method"] == method
    assert state["probe_ok"] is True


def test_not_logged_in_exit_code_still_reads_the_json():
    with _patch_run(return_value=_cp(_status(False, "none"), returncode=1)):
        state = auth_mod.claude_code_login_state(force=True)
    assert state["connected"] is False
    assert state["probe_ok"] is True


def test_probe_runs_auth_status_with_the_scrubbed_provider_env(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-api03-synthetic")
    monkeypatch.setenv("ANTHROPIC_TOKEN", "sk-ant-oat01-synthetic")
    with _patch_run(return_value=_cp(_status())) as run:
        auth_mod.claude_code_login_state(force=True)
    argv = run.call_args.args[0]
    kwargs = run.call_args.kwargs
    assert argv == [CLAUDE, "auth", "status"]
    assert kwargs["timeout"] <= 2.0
    assert "ANTHROPIC_API_KEY" not in kwargs["env"]
    assert "ANTHROPIC_TOKEN" not in kwargs["env"]


def test_probe_env_carries_the_managed_setup_token(monkeypatch):
    monkeypatch.setenv("HERMES_CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-managed")
    with _patch_run(return_value=_cp(_status(True, "oauth_token"))) as run:
        auth_mod.claude_code_login_state(force=True)
    assert run.call_args.kwargs["env"]["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-ant-oat01-managed"


def test_stored_setup_token_counts_as_connected(monkeypatch):
    monkeypatch.setattr(auth_mod, "has_claude_code_setup_token", lambda: True)
    with _patch_run(return_value=_cp(_status(False, "none"))):
        assert auth_mod.claude_code_login_state(force=True)["connected"] is True


# ── probe failures: assume connected (the CLI's own error is the backstop) ──


@pytest.mark.parametrize(
    "run_kwargs",
    [
        {"side_effect": subprocess.TimeoutExpired(cmd="claude", timeout=2.0)},
        {"side_effect": OSError("exec format error")},
        {"return_value": _cp("Update available! Run claude update")},
        {"return_value": _cp("")},
    ],
)
def test_probe_failure_is_treated_as_connected(run_kwargs):
    with _patch_run(**run_kwargs):
        state = auth_mod.claude_code_login_state(force=True)
    assert state["connected"] is True
    assert state["probe_ok"] is False


def test_missing_binary_is_not_connected_and_not_probed(monkeypatch):
    monkeypatch.setattr(auth_mod.shutil, "which", lambda c: None)
    with _patch_run() as run:
        state = auth_mod.claude_code_login_state(force=True)
    assert state["connected"] is False
    run.assert_not_called()


# ── cache: positive 60 s, negative never ────────────────────────────────────


def test_positive_result_is_cached_for_a_minute(monkeypatch):
    now = [1000.0]
    monkeypatch.setattr(auth_mod.time, "monotonic", lambda: now[0])
    with _patch_run(return_value=_cp(_status())) as run:
        assert auth_mod.claude_code_login_state()["connected"] is True
        now[0] += 30
        assert auth_mod.claude_code_login_state()["connected"] is True
        assert run.call_count == 1
        now[0] += 31  # past 60 s
        auth_mod.claude_code_login_state()
        assert run.call_count == 2


def test_force_bypasses_the_cache():
    with _patch_run(return_value=_cp(_status())) as run:
        auth_mod.claude_code_login_state()
        auth_mod.claude_code_login_state(force=True)
    assert run.call_count == 2


def test_negative_result_is_cached_only_briefly(monkeypatch):
    # Short enough that signing in shows within seconds; long enough that the
    # pre-warm outside the WebUI env lock and the call inside it share one probe.
    clock = {"t": 1000.0}
    monkeypatch.setattr(auth_mod.time, "monotonic", lambda: clock["t"])
    with _patch_run(return_value=_cp(_status(True, "api_key"))) as run:
        auth_mod.claude_code_login_state()
        auth_mod.claude_code_login_state()
        assert run.call_count == 1
        clock["t"] += auth_mod._CLAUDE_CODE_LOGIN_NEGATIVE_TTL_SECONDS + 1
        auth_mod.claude_code_login_state()
    assert run.call_count == 2


def test_logged_in_without_an_auth_method_field_counts_as_connected():
    # Older CLIs don't report authMethod; the probe env has no API key, so
    # logged in there means the subscription login.
    with _patch_run(return_value=_cp(json.dumps({"loggedIn": True}))):
        state = auth_mod.claude_code_login_state(force=True)
    assert state["connected"] is True


def test_cached_state_is_a_copy():
    with _patch_run(return_value=_cp(_status())):
        first = auth_mod.claude_code_login_state()
        first["connected"] = False
        assert auth_mod.claude_code_login_state()["connected"] is True


# ── resolve / status use the probe ──────────────────────────────────────────


@pytest.mark.parametrize("method", ["api_key", "none"])
def test_resolve_raises_no_claude_account_when_not_connected(method):
    with _patch_run(return_value=_cp(_status(method != "none", method))):
        with pytest.raises(auth_mod.AuthError) as excinfo:
            auth_mod.resolve_external_process_provider_credentials("claude-code")
    msg = str(excinfo.value)
    assert msg.startswith(NO_CLAUDE_ACCOUNT)
    assert "claude /login" in msg
    # The loop, WebUI and voice treat it as a missing credential (no fallback).
    assert classify_api_error(excinfo.value).reason is FailoverReason.missing_credential


def test_resolve_returns_the_marker_runtime_when_connected():
    with _patch_run(return_value=_cp(_status(True, "claude.ai"))):
        creds = auth_mod.resolve_external_process_provider_credentials("claude-code")
    assert creds["provider"] == "claude-code"
    assert creds["base_url"] == "claude-cli://local"
    assert creds["command"] == CLAUDE
    assert creds["api_key"] == "claude-code"


def test_status_reports_api_key_login_as_not_logged_in():
    with _patch_run(return_value=_cp(_status(True, "api_key", ""))):
        status = auth_mod.get_external_process_provider_status("claude-code")
    assert status["logged_in"] is False
    assert status["auth_method"] == "api_key"
    assert status["configured"] is True


def test_status_reports_subscription_login():
    with _patch_run(return_value=_cp(_status(True, "claude.ai", "max"))):
        status = auth_mod.get_external_process_provider_status("claude-code")
    assert status["logged_in"] is True
    assert status["auth_method"] == "claude.ai"
    assert status["subscription_type"] == "max"


def test_setup_token_change_shows_despite_a_cached_probe(monkeypatch):
    token = {"stored": False}
    monkeypatch.setattr(auth_mod, "has_claude_code_setup_token", lambda: token["stored"])
    with _patch_run(return_value=_cp(_status())) as run:
        assert auth_mod.claude_code_login_state()["has_setup_token"] is False
        token["stored"] = True
        assert auth_mod.claude_code_login_state()["has_setup_token"] is True
    assert run.call_count == 1
