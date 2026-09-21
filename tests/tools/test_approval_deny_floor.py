"""`approvals.deny` is an operator floor, not a preference.

Everything a user could express before this only ever widened what runs: the
permanent allowlist, `approvals.mode`, session approvals, `--yolo`,
`cron_mode: approve`. The shipped hardline table was the one thing yolo could
not cross, and it is not editable. These tests pin the properties that make a
deny rule a floor -- if any of them regress, the feature still *looks* like it
works while not working.
"""

from unittest.mock import patch

import pytest

from tools.approval import (
    check_dangerous_command,
    detect_denied_command,
    explain_command,
    load_deny_globs,
)


@pytest.fixture
def deny(tmp_path, monkeypatch):
    """Write an approvals.deny list into an isolated HERMES_HOME."""
    def _write(*globs, extra=""):
        body = "approvals:\n"
        if extra:
            body += extra
        if globs:
            body += "  deny:\n" + "".join(f'    - "{g}"\n' for g in globs)
        (tmp_path / "config.yaml").write_text(body)
        monkeypatch.setenv("HERMES_HOME", str(tmp_path))
        return tmp_path
    return _write


class TestNothingBypassesIt:
    """The whole point: these are the doors that exist, and it closes all."""

    def test_yolo_cannot_lift_it(self, deny, monkeypatch):
        deny("*--force*")
        monkeypatch.setenv("HERMES_YOLO_MODE", "1")
        result = check_dangerous_command("git push --force", "local")
        assert result["approved"] is False
        assert result["denied_by"] == "*--force*"

    def test_approvals_mode_off_cannot_lift_it(self, deny):
        deny("*--force*", extra="  mode: off\n")
        assert check_dangerous_command("git push --force", "local")["approved"] is False

    def test_cron_approve_mode_cannot_lift_it(self, deny, monkeypatch):
        deny("*--force*", extra="  cron_mode: approve\n")
        monkeypatch.setenv("HERMES_CRON_SESSION", "1")
        assert check_dangerous_command("git push --force", "local")["approved"] is False

    def test_all_three_at_once_cannot_lift_it(self, deny, monkeypatch):
        deny("*--force*", extra="  mode: off\n  cron_mode: approve\n")
        monkeypatch.setenv("HERMES_YOLO_MODE", "1")
        monkeypatch.setenv("HERMES_CRON_SESSION", "1")
        assert check_dangerous_command("git push --force", "local")["approved"] is False

    def test_the_block_names_the_rule_that_fired(self, deny):
        deny("*/.ssh/*")
        result = check_dangerous_command("cat ~/.ssh/id_rsa", "local")
        assert result["denied_by"] == "*/.ssh/*"
        assert "*/.ssh/*" in result["message"]


class TestBypassesThatWouldMakeItFake:
    def test_a_chained_command_cannot_walk_around_it(self, deny):
        """`ls && rm -rf /tmp/x` must not defeat an `rm -rf*` rule."""
        deny("rm -rf*")
        assert detect_denied_command("ls && rm -rf /tmp/x")[0] is True

    @pytest.mark.parametrize("sep", ["&&", "||", ";", "|"])
    def test_every_separator_is_split(self, deny, sep):
        deny("rm -rf*")
        assert detect_denied_command(f"echo hi {sep} rm -rf /tmp/x")[0] is True

    def test_newline_chaining_is_split(self, deny):
        deny("rm -rf*")
        assert detect_denied_command("echo hi\nrm -rf /tmp/x")[0] is True

    def test_ansi_obfuscation_cannot_walk_around_it(self, deny):
        """Matched on the normalized text, like the dangerous detector."""
        deny("*--force*")
        assert detect_denied_command("git push \x1b[0m--force")[0] is True

    def test_case_does_not_matter(self, deny):
        deny("*--force*")
        assert detect_denied_command("GIT PUSH --FORCE")[0] is True


class TestItStaysOutOfTheWay:
    def test_no_deny_list_changes_nothing(self, deny):
        deny()
        assert detect_denied_command("git push --force") == (False, None)
        assert load_deny_globs() == []

    def test_unrelated_commands_still_run(self, deny):
        deny("*--force*")
        assert check_dangerous_command("git status", "local")["approved"] is True

    def test_sandboxed_backends_still_bypass(self, deny):
        """A container cannot damage the host, so the layer is skipped there."""
        deny("*--force*")
        assert check_dangerous_command("git push --force", "docker")["approved"] is True


class TestMalformedConfigFailsOpen:
    """Failing closed would brick the agent on a typo."""

    def test_unreadable_config_yields_no_rules(self, tmp_path, monkeypatch):
        monkeypatch.setenv("HERMES_HOME", str(tmp_path))
        with patch("jarviscopilot_cli.config.load_config", side_effect=OSError("boom")):
            assert load_deny_globs() == []

    def test_non_list_deny_is_ignored(self, tmp_path, monkeypatch):
        (tmp_path / "config.yaml").write_text("approvals:\n  deny: 'rm -rf /*'\n")
        monkeypatch.setenv("HERMES_HOME", str(tmp_path))
        assert load_deny_globs() == []

    def test_non_string_entries_are_skipped(self, tmp_path, monkeypatch):
        (tmp_path / "config.yaml").write_text(
            'approvals:\n  deny:\n    - 17\n    - "rm -rf /*"\n    - ""\n')
        monkeypatch.setenv("HERMES_HOME", str(tmp_path))
        assert load_deny_globs() == ["rm -rf /*"]


class TestExplainCommand:
    """`approvals test` has to report the same chain that actually runs."""

    def test_reports_the_deny_layer(self, deny):
        deny("*--force*")
        out = explain_command("git push --force")
        assert out["decision"] == "blocked"
        assert out["layer"] == "approvals.deny"
        assert out["detail"] == "*--force*"

    def test_hardline_outranks_the_operator_floor(self, deny):
        """Order matters: the shipped floor is checked first."""
        deny("*rm*")
        assert explain_command("rm -rf /")["layer"] == "hardline"

    def test_reports_prompt_for_a_merely_dangerous_command(self, deny):
        deny()
        assert explain_command("chmod 777 /etc/passwd")["decision"] == "prompt"

    def test_reports_run_for_an_ordinary_command(self, deny):
        deny()
        out = explain_command("ls -la")
        assert out["decision"] == "run"
        assert out["layer"] == "not-dangerous"

    def test_reports_the_sandbox_bypass(self, deny):
        deny("*--force*")
        out = explain_command("git push --force", env_type="docker")
        assert out["decision"] == "run"
        assert out["layer"] == "sandbox"

    def test_yolo_is_reported_as_the_decider(self, deny, monkeypatch):
        deny()
        monkeypatch.setenv("HERMES_YOLO_MODE", "1")
        assert explain_command("chmod 777 /etc/passwd")["layer"] == "yolo"

    def test_explaining_never_executes(self, deny, tmp_path):
        """The command text is never handed to a shell."""
        deny()
        canary = tmp_path / "canary"
        explain_command(f"touch {canary}")
        assert not canary.exists()
