"""A run with nobody there to approve refuses dangerous commands.

A messaging harness node that works in the background after the turn has ended
(gateway/harness_turns.py) runs on a plain thread: no gateway context, no CLI,
so the approval check used to wave every dangerous command through. Inside
``unattended_run()`` it now refuses them, the way a cron job does by default."""
import pytest

from tools import approval

DANGEROUS = "rm -rf /tmp/jc-unattended-test"
CHECKS = [approval.check_dangerous_command, approval.check_all_command_guards]


@pytest.fixture(autouse=True)
def _non_interactive(monkeypatch):
    for key in ("HERMES_INTERACTIVE", "HERMES_GATEWAY_SESSION", "HERMES_CRON_SESSION", "HERMES_EXEC_ASK",
                "HERMES_YOLO_MODE", "HERMES_SESSION_PLATFORM"):
        monkeypatch.delenv(key, raising=False)


@pytest.mark.parametrize("check", CHECKS)
def test_unattended_runs_refuse_dangerous_commands(check):
    with approval.unattended_run():
        out = check(DANGEROUS, "local")
    assert out["approved"] is False and "BLOCKED" in out["message"]


@pytest.mark.parametrize("check", CHECKS)
def test_safe_commands_still_run(check):
    with approval.unattended_run():
        assert check("ls -la", "local")["approved"] is True


def test_the_flag_ends_with_the_block():
    with approval.unattended_run():
        pass
    # Outside it, today's non-interactive behaviour is unchanged.
    assert approval.check_dangerous_command(DANGEROUS, "local")["approved"] is True
