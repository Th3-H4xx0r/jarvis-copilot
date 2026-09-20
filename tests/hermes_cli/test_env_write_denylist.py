"""The env writer refuses names that would escalate privilege.

``.env`` is loaded into ``os.environ`` for every subprocess JarvisCopilot
spawns, and the dashboard exposes a write surface over it (``PUT /api/env``).
Without a denylist, one write of ``HERMES_YOLO_MODE`` disables the approval
gate for every future run, and ``LD_PRELOAD`` / ``BASH_ENV`` / ``GIT_SSH_COMMAND``
are straightforward code execution.
"""

import os
from unittest.mock import patch

import pytest

from jarviscopilot_cli.config import (
    _env_var_policy_name,
    validate_config_write,
    load_env,
    save_env_value,
    save_env_value_secure,
    validate_env_var_name_for_write,
)


class TestWriterDenylist:
    def test_approval_gate_flag_cannot_be_persisted(self, tmp_path):
        """The escalation this denylist exists to stop."""
        with patch.dict(os.environ, {"HERMES_HOME": str(tmp_path)}):
            with pytest.raises(ValueError, match="denylist"):
                save_env_value("HERMES_YOLO_MODE", "1")
            assert "HERMES_YOLO_MODE" not in load_env()

    @pytest.mark.parametrize(
        "name",
        [
            "PATH",
            "EDITOR",
            "BASH_ENV",
            "GIT_SSH_COMMAND",
            "PYTHONPATH",
            "NODE_OPTIONS",
            "HERMES_HOME",
            "HERMES_REDACT_SECRETS",
        ],
    )
    def test_execution_steering_names_are_refused(self, tmp_path, name):
        with patch.dict(os.environ, {"HERMES_HOME": str(tmp_path)}):
            with pytest.raises(ValueError, match="denylist"):
                save_env_value(name, "anything")

    @pytest.mark.parametrize(
        "name",
        ["LD_PRELOAD", "LD_SOMETHING_NEW", "DYLD_INSERT_LIBRARIES",
         "GIT_CONFIG_KEY_17", "GIT_CONFIG_COUNT"],
    )
    def test_prefix_families_cover_unbounded_names(self, tmp_path, name):
        """Enumeration cannot cover GIT_CONFIG_KEY_<n>; the prefix must."""
        with patch.dict(os.environ, {"HERMES_HOME": str(tmp_path)}):
            with pytest.raises(ValueError, match="denylist"):
                save_env_value(name, "anything")

    def test_secure_writer_inherits_the_guard(self, tmp_path):
        with patch.dict(os.environ, {"HERMES_HOME": str(tmp_path)}):
            with pytest.raises(ValueError, match="denylist"):
                save_env_value_secure("LD_PRELOAD", "/tmp/evil.so")

    def test_invalid_syntax_still_rejected_separately(self, tmp_path):
        with patch.dict(os.environ, {"HERMES_HOME": str(tmp_path)}):
            with pytest.raises(ValueError, match="Invalid environment variable"):
                save_env_value("not-a-valid-name", "x")


class TestDenylistDoesNotBreakSetup:
    """Provider/integration credentials must keep working -- the denylist is
    name-by-name precisely so it cannot break a setup wizard."""

    @pytest.mark.parametrize(
        "name",
        [
            "OPENAI_API_KEY",
            "TELEGRAM_BOT_TOKEN",
            "HERMES_SPOTIFY_CLIENT_ID",
            "TERMINAL_SSH_HOST",
            "GITHUB_TOKEN",
            "SUDO_PASSWORD",
        ],
    )
    def test_ordinary_credentials_still_write(self, tmp_path, name):
        with patch.dict(os.environ, {"HERMES_HOME": str(tmp_path)}):
            save_env_value(name, "value-for-test")
            assert load_env()[name] == "value-for-test"

    def test_hermes_prefix_is_not_blanket_blocked(self):
        """A blanket HERMES_* block would break integration credentials."""
        validate_env_var_name_for_write("HERMES_SPOTIFY_CLIENT_ID")


class TestWriteOnlyEnforcement:
    def test_preexisting_denylisted_value_still_loads(self, tmp_path):
        """Enforcement is on write. A hand-edited .env keeps working."""
        env_path = tmp_path / ".env"
        env_path.write_text("EDITOR=vim\nOPENAI_API_KEY=sk-REDACTED\n")
        with patch.dict(os.environ, {"HERMES_HOME": str(tmp_path)}):
            values = load_env()
            assert values["EDITOR"] == "vim"
            assert values["OPENAI_API_KEY"] == "sk-REDACTED"


class TestPlatformCaseSemantics:
    def test_windows_env_names_compare_case_insensitively(self):
        assert _env_var_policy_name("path", is_windows=True) == "PATH"

    def test_posix_env_names_are_case_sensitive(self):
        assert _env_var_policy_name("path", is_windows=False) == "path"


class TestEscalationNamesFoundByReview:
    """Names an adversarial pass found still writable after the first pass."""

    @pytest.mark.parametrize(
        "name",
        [
            "HOME",                          # repoints ~/.gitconfig, ~/.ssh/config
            "USERPROFILE",
            "XDG_CONFIG_HOME",
            "TMPDIR",
            "HERMES_ENABLE_PROJECT_PLUGINS",  # imports cwd plugins -> in-process RCE
            "HERMES_GIT_BASH_PATH",           # the bash.exe every Windows command uses
            "PYTHONWARNINGS",                 # imports a module at interpreter start
            "GIT_CONFIG",                     # no underscore, so the prefix missed it
            "LESSOPEN",
            "RUSTC_WRAPPER",
            "PIP_INDEX_URL",
        ],
    )
    def test_execution_steering_names_are_refused(self, tmp_path, name):
        with patch.dict(os.environ, {"HERMES_HOME": str(tmp_path)}):
            with pytest.raises(ValueError, match="denylist"):
                save_env_value(name, "anything")

    @pytest.mark.parametrize("name", ["PATH\n", "HERMES_YOLO_MODE\n", "HOME\n"])
    def test_trailing_newline_does_not_smuggle_a_name_through(self, tmp_path, name):
        """`$` also matches before a trailing newline, so match() accepted
        "PATH\n" and then wrote a corrupt .env line."""
        with patch.dict(os.environ, {"HERMES_HOME": str(tmp_path)}):
            with pytest.raises(ValueError):
                save_env_value(name, "/tmp/evil")
            assert not (tmp_path / ".env").exists()


class TestConfigWriteIsGatedToo:
    """The env denylist is decorative if the same token can write
    `approvals.mode: off` through PUT /api/config instead."""

    CURRENT = {
        "approvals": {"mode": "manual"},
        "terminal": {"backend": "local"},
        "security": {"redact_secrets": True},
        "display": {"skin": "default"},
    }

    @pytest.mark.parametrize(
        "incoming",
        [
            {"approvals": {"mode": "off"}},
            {"approvals": {"cron_mode": "approve"}},
            {"terminal": {"backend": "docker"}},
            {"security": {"redact_secrets": False}},
            {"skills": {"inline_shell": True}},
        ],
    )
    def test_changing_a_protected_key_is_refused(self, incoming):
        with pytest.raises(ValueError):
            validate_config_write(incoming, self.CURRENT)

    def test_unchanged_round_trip_is_allowed(self):
        """The dashboard PUTs the whole document on every save."""
        validate_config_write(dict(self.CURRENT), self.CURRENT)

    def test_ordinary_settings_still_writable(self):
        validate_config_write({"display": {"skin": "ares"}}, self.CURRENT)
