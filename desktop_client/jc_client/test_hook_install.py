"""Installing jc-hook into ~/.claude/settings.json — the file belongs to the
user: never clobber what's there, back it up, write only what was previewed."""
import json
import os

import pytest

from jc_client import hook_install as hi

CMD = '"/py" -I "/bin/jc-hook"'


def write(path, obj):
    path.write_text(json.dumps(obj, indent=2))
    return path.read_bytes()


@pytest.fixture
def paths(tmp_path):
    settings = tmp_path / "claude" / "settings.json"
    settings.parent.mkdir()
    bindir = tmp_path / "bin"
    bindir.mkdir()
    return settings, bindir


def entries(settings_obj, event):
    out = []
    for g in settings_obj.get("hooks", {}).get(event, []):
        for h in g.get("hooks", []):
            out.append((g.get("matcher"), h.get("command"), h.get("timeout")))
    return out


def test_fresh_install_adds_every_event_and_the_ask_matcher(paths):
    settings, bindir = paths
    pv = hi.preview(str(settings), CMD, str(bindir))
    hi.install(str(settings), pv)
    obj = json.loads(settings.read_text())
    for event, timeout in hi.CLAUDE_EVENTS:
        assert (None, CMD, timeout) in entries(obj, event)
    assert ("AskUserQuestion", CMD + " --ask", 130) in entries(obj, "PreToolUse")
    assert dict(hi.CLAUDE_EVENTS)["PermissionRequest"] == 120
    assert obj["statusLine"]["command"] == CMD + " --statusline"


def test_preserves_foreign_hooks(paths):
    settings, bindir = paths
    write(settings, {"model": "opus", "hooks": {"PreToolUse": [
        {"matcher": "Grep|Glob|Bash", "hooks": [{"type": "command", "command": "node gitnexus.cjs",
                                                 "timeout": 10}]}]}})
    hi.install(str(settings), hi.preview(str(settings), CMD, str(bindir)))
    obj = json.loads(settings.read_text())
    assert obj["model"] == "opus"
    assert ("Grep|Glob|Bash", "node gitnexus.cjs", 10) in entries(obj, "PreToolUse")
    assert (None, CMD, 10) in entries(obj, "PreToolUse")


def test_statusline_chains_previous(paths):
    settings, bindir = paths
    write(settings, {"statusLine": {"type": "command", "command": "node ads.mjs", "padding": 0}})
    hi.install(str(settings), hi.preview(str(settings), CMD, str(bindir)))
    obj = json.loads(settings.read_text())
    assert obj["statusLine"] == {"type": "command", "command": CMD + " --statusline", "padding": 0}
    prev = json.loads((bindir / "statusline-previous.json").read_text())
    assert prev["command"] == "node ads.mjs"
    hi.uninstall(str(settings), str(bindir))
    obj = json.loads(settings.read_text())
    assert obj["statusLine"] == {"type": "command", "command": "node ads.mjs", "padding": 0}
    assert not (bindir / "statusline-previous.json").exists()


def test_reinstall_is_idempotent(paths):
    settings, bindir = paths
    write(settings, {"statusLine": {"type": "command", "command": "node ads.mjs"}})
    hi.install(str(settings), hi.preview(str(settings), CMD, str(bindir)))
    first = settings.read_text()
    hi.install(str(settings), hi.preview(str(settings), CMD, str(bindir)))
    assert settings.read_text() == first
    prev = json.loads((bindir / "statusline-previous.json").read_text())
    assert prev["command"] == "node ads.mjs"  # never replaced by our own command


def test_backup_is_written(paths):
    settings, bindir = paths
    original = write(settings, {"theme": "dark"})
    hi.install(str(settings), hi.preview(str(settings), CMD, str(bindir)))
    backups = [p for p in os.listdir(settings.parent) if p.startswith("settings.json.jc-backup-")]
    assert len(backups) == 1
    assert (settings.parent / backups[0]).read_bytes() == original


def test_refuses_when_file_changed_after_preview(paths):
    settings, bindir = paths
    write(settings, {"theme": "dark"})
    pv = hi.preview(str(settings), CMD, str(bindir))
    write(settings, {"theme": "light"})
    with pytest.raises(hi.SettingsChanged):
        hi.install(str(settings), pv)
    assert json.loads(settings.read_text()) == {"theme": "light"}


def test_refuses_unknown_shapes(paths):
    settings, bindir = paths
    write(settings, {"hooks": ["not", "a", "dict"]})
    with pytest.raises(hi.SettingsShape):
        hi.preview(str(settings), CMD, str(bindir))
    settings.write_text("{not json")
    with pytest.raises(hi.SettingsShape):
        hi.preview(str(settings), CMD, str(bindir))


def test_uninstall_removes_only_ours(paths):
    settings, bindir = paths
    write(settings, {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}})
    hi.install(str(settings), hi.preview(str(settings), CMD, str(bindir)))
    hi.uninstall(str(settings), str(bindir))
    obj = json.loads(settings.read_text())
    assert obj["hooks"] == {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}
    assert "statusLine" not in obj


def test_status_reports_installed_and_outdated(paths):
    settings, bindir = paths
    assert hi.status(str(settings))["installed"] is False
    hi.install(str(settings), hi.preview(str(settings), CMD, str(bindir)))
    st = hi.status(str(settings))
    assert st["installed"] is True and st["outdated"] is False and st["statusline"] is True
    obj = json.loads(settings.read_text())
    obj["hooks"].pop("PostCompact")
    settings.write_text(json.dumps(obj))
    assert hi.status(str(settings))["outdated"] is True


def test_diff_shows_the_change(paths):
    settings, bindir = paths
    write(settings, {"theme": "dark"})
    pv = hi.preview(str(settings), CMD, str(bindir))
    assert "+" in pv.diff and "PermissionRequest" in pv.diff


def test_install_script_copies_the_relay(paths):
    _, bindir = paths
    path = hi.install_script(str(bindir))
    assert os.path.basename(path) == "jc-hook"
    assert os.access(path, os.X_OK)
    assert "def main(argv, raw, env)" in open(path).read()


def test_command_base_quotes_paths():
    assert hi.command_base("/a b/python", "/c/jc-hook") == '"/a b/python" -I "/c/jc-hook"'
    assert hi.command_base("/py", "/c/jc-hook", socket="/s.sock") == \
        '"/py" -I "/c/jc-hook" --socket "/s.sock"'
