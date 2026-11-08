from types import SimpleNamespace
from unittest.mock import patch

from jarviscopilot_cli.config import (
    format_managed_message,
    get_managed_system,
    recommended_update_command,
)
from jarviscopilot_cli.main import cmd_update
from tools.skills_hub import OptionalSkillSource


def test_unnamed_managed_install_gets_generic_guidance(monkeypatch):
    monkeypatch.setenv("HERMES_MANAGED", "true")

    assert get_managed_system() == "a package manager"
    assert "package manager" in recommended_update_command()
    assert "managed by a package manager" in format_managed_message("update")


def test_get_managed_system_homebrew(monkeypatch):
    monkeypatch.setenv("HERMES_MANAGED", "homebrew")

    assert get_managed_system() == "Homebrew"
    assert recommended_update_command() == "brew upgrade jarviscopilot"


def test_format_managed_message_homebrew(monkeypatch):
    monkeypatch.setenv("HERMES_MANAGED", "homebrew")

    message = format_managed_message("update JarvisCopilot Agent")

    assert "managed by Homebrew" in message
    assert "brew upgrade jarviscopilot" in message


def test_recommended_update_command_defaults_to_hermes_update(monkeypatch):
    monkeypatch.delenv("HERMES_MANAGED", raising=False)

    # Also short-circuit the .managed marker path, in case an ambient marker
    # makes get_managed_update_command() answer before detect_install_method().
    with patch("jarviscopilot_cli.config.get_managed_update_command", return_value=None), \
         patch("jarviscopilot_cli.config.detect_install_method", return_value="git"):
        assert recommended_update_command() == "jarviscopilot update"


def test_cmd_update_blocks_managed_homebrew(monkeypatch, capsys):
    monkeypatch.setenv("HERMES_MANAGED", "homebrew")

    with patch("jarviscopilot_cli.main.subprocess.run") as mock_run:
        cmd_update(SimpleNamespace())

    assert not mock_run.called
    captured = capsys.readouterr()
    assert "managed by Homebrew" in captured.err
    assert "brew upgrade jarviscopilot" in captured.err


def test_optional_skill_source_honors_env_override(monkeypatch, tmp_path):
    optional_dir = tmp_path / "optional-skills"
    optional_dir.mkdir()
    monkeypatch.setenv("HERMES_OPTIONAL_SKILLS", str(optional_dir))

    source = OptionalSkillSource()

    assert source._optional_dir == optional_dir


def test_ensure_hermes_home_creates_missing_dirs_when_managed(monkeypatch, tmp_path):
    """A managed (e.g. Homebrew) first run must create HERMES_HOME, not
    demand a NixOS activation script that pre-creates it."""
    from jarviscopilot_cli.config import ensure_hermes_home

    home = tmp_path / "fresh-home"
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setenv("HERMES_MANAGED", "homebrew")

    ensure_hermes_home()

    for sub in ("cron", "sessions", "logs/curator", "memories", "skills"):
        assert (home / sub).is_dir()
    assert (home / "SOUL.md").exists()
