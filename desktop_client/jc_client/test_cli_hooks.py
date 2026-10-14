"""`jc-client hooks …` — install the relay into Claude Code's settings."""
import json

from jc_client import cli, hook_install


def setup(tmp_path, monkeypatch):
    settings = tmp_path / "settings.json"
    settings.write_text(json.dumps({"theme": "dark"}))
    monkeypatch.setattr(cli, "_hooks_settings_path", lambda: str(settings))
    monkeypatch.setattr(cli, "_hooks_bin_dir", lambda: str(tmp_path / "bin"))
    return settings


def test_install_with_yes_writes_and_status_reports(tmp_path, monkeypatch, capsys):
    settings = setup(tmp_path, monkeypatch)
    assert cli.main(["hooks", "install", "--yes"]) == 0
    obj = json.loads(settings.read_text())
    assert obj["theme"] == "dark" and "PermissionRequest" in obj["hooks"]
    assert (tmp_path / "bin" / "jc-hook").exists()
    capsys.readouterr()
    assert cli.main(["hooks", "status"]) == 0
    assert json.loads(capsys.readouterr().out)["installed"] is True


def test_install_without_yes_asks_and_respects_no(tmp_path, monkeypatch):
    settings = setup(tmp_path, monkeypatch)
    monkeypatch.setattr("builtins.input", lambda _prompt="": "n")
    assert cli.main(["hooks", "install"]) == 1
    assert json.loads(settings.read_text()) == {"theme": "dark"}


def test_preview_prints_the_diff(tmp_path, monkeypatch, capsys):
    settings = setup(tmp_path, monkeypatch)
    assert cli.main(["hooks", "preview"]) == 0
    assert "PermissionRequest" in capsys.readouterr().out
    assert json.loads(settings.read_text()) == {"theme": "dark"}


def test_uninstall(tmp_path, monkeypatch):
    settings = setup(tmp_path, monkeypatch)
    cli.main(["hooks", "install", "--yes"])
    assert cli.main(["hooks", "uninstall"]) == 0
    assert hook_install.status(str(settings))["installed"] is False
