"""The PC's skills: the same names and arguments as the Mac's (the server finds a computer's
skills by name), and the pure Windows rules. Read by AST so nothing registers on the Mac."""
import ast
import os

import pytest

from jc_client.skills import _win_helpers as h

_SKILLS = os.path.join(os.path.dirname(__file__), "skills")
MAC_ONLY = {"messages_send"}   # iMessage: no Windows API (spec §5)


def _skills_in(path):
    """{name: sorted argument names} for every @skill(...) function in a module."""
    tree = ast.parse(open(path, encoding="utf-8").read())
    out = {}
    for node in tree.body:
        if not isinstance(node, ast.FunctionDef):
            continue
        for dec in node.decorator_list:
            if isinstance(dec, ast.Call) and getattr(dec.func, "id", "") == "skill" and dec.args:
                name = dec.args[0].value
                out[name] = sorted(a.arg for a in node.args.args)
    return out


def test_pc_offers_every_mac_skill_but_imessage():
    mac = _skills_in(os.path.join(_SKILLS, "mac.py"))
    win = _skills_in(os.path.join(_SKILLS, "windows.py"))
    missing = set(mac) - set(win) - MAC_ONLY
    assert not missing, f"the PC lacks {sorted(missing)}"


def test_shared_skills_take_the_same_arguments():
    mac = _skills_in(os.path.join(_SKILLS, "mac.py"))
    win = _skills_in(os.path.join(_SKILLS, "windows.py"))
    for name in set(mac) & set(win):
        assert win[name] == mac[name], f"{name}: PC {win[name]} vs Mac {mac[name]}"


def test_image_name_appends_exe_only_when_missing():
    assert h.image_name("explorer") == "explorer.exe"
    assert h.image_name("Code.exe") == "Code.exe"
    assert h.image_name("  spotify ") == "spotify.exe"


def test_volume_script_reads_and_sets():
    assert h.volume_script().rstrip().endswith("[JcAudio]::Get()")
    s = h.volume_script(40)
    assert "[JcAudio]::Set(0.40)" in s
    assert "[JcAudio]::Set(1.00)" in h.volume_script(150)
    assert "[JcAudio]::Set(0.00)" in h.volume_script(-5)


def test_media_play_pause_follow_the_macs_rules():
    assert h.media_plan("play", True) == (None, {"ok": True, "action": "play", "changed": False, "playing": True})
    assert h.media_plan("pause", False) == (None, {"ok": True, "action": "pause", "changed": False, "playing": False})
    assert h.media_plan("pause", True)[0] == 0xB3
    assert h.media_plan("next", None)[0] == 0xB0
    assert h.media_plan("previous", None)[0] == 0xB1
    assert h.media_plan("status", True) == (None, {"ok": True, "action": "status", "playing": True})


def test_media_rejects_unknown_action():
    with pytest.raises(ValueError):
        h.media_plan("louder", None)


def test_system_commands_cover_the_macs_list():
    mac_cmds = {"copy", "paste", "cut", "undo", "redo", "selectall", "save", "quit", "minimize",
                "switchapp", "newtab", "closetab", "newwindow", "closewindow", "find", "refresh",
                "screenshot", "spotlight"}
    assert set(h.SYSTEM_COMBOS) == mac_cmds
    assert h.SYSTEM_COMBOS["copy"] == ["ctrl", "c"] and h.SYSTEM_COMBOS["refresh"] == ["f5"]


def test_spotify_uri_same_as_mac():
    assert h.SPOTIFY_URI.fullmatch("spotify:track:0VjIjW4GlUZAMYd2vXMi3b")
    assert not h.SPOTIFY_URI.fullmatch("https://open.spotify.com/track/x")


def test_open_app_resolves_windows_app_names(monkeypatch):
    """Live: Start-Process -FilePath "Calculator" → "cannot find the file specified"."""
    from jc_client.skills import windows as w
    assert w.app_command("Calculator") == "calc.exe"
    assert w.app_command("settings") == w.app_command("System Settings") == "ms-settings:"
    assert w.app_command("File Explorer") == w.app_command("Finder") == "explorer.exe"
    assert w.app_command("notepad") == "notepad.exe"
    assert w.app_command("Spotify") == "Spotify"            # unknown names pass through
    seen = []
    monkeypatch.setattr(w, "_ps", lambda script, **kw: seen.append((script, kw.get("env"))) or "")
    w.open_app("Calculator")
    script, env = seen[0]
    assert env == {"JC_APP": "calc.exe"} and "Get-StartApps" in script   # Start-menu apps as a fallback
