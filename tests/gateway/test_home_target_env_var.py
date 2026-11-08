"""Regression tests for /sethome env-var resolution.

The `/sethome` command writes to a platform's home-target env var. Email
doesn't follow the `{PLATFORM}_HOME_CHANNEL` convention: it uses
`EMAIL_HOME_ADDRESS`. Before PR #12698 `/sethome` hardcoded the `_HOME_CHANNEL`
suffix, so Email saves went to env vars nothing read on startup — the home
channel appeared to set successfully but was lost on every new gateway session.
"""

from gateway.run import _home_target_env_var, _home_thread_env_var


def test_email_home_target_env_var_uses_home_address():
    assert _home_target_env_var("email") == "EMAIL_HOME_ADDRESS"


def test_telegram_home_target_env_var_uses_home_channel():
    assert _home_target_env_var("telegram") == "TELEGRAM_HOME_CHANNEL"


def test_discord_home_target_env_var_uses_home_channel():
    assert _home_target_env_var("discord") == "DISCORD_HOME_CHANNEL"


def test_unknown_platform_home_target_env_var_falls_back_to_home_channel():
    assert _home_target_env_var("custom") == "CUSTOM_HOME_CHANNEL"


def test_case_insensitive_platform_name():
    assert _home_target_env_var("TELEGRAM") == "TELEGRAM_HOME_CHANNEL"
    assert _home_target_env_var("Email") == "EMAIL_HOME_ADDRESS"


def test_home_thread_env_var_uses_home_target_name_plus_thread_id():
    assert _home_thread_env_var("discord") == "DISCORD_HOME_CHANNEL_THREAD_ID"
    assert _home_thread_env_var("email") == "EMAIL_HOME_ADDRESS_THREAD_ID"
