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



def test_open_url_in_a_named_browser(monkeypatch):
    from jc_client.skills import windows as w
    assert w.app_command("Google Chrome") == w.app_command("chrome") == "chrome.exe"
    seen = []
    monkeypatch.setattr(w, "_ps", lambda script, **kw: seen.append((script, kw.get("env"))) or "")
    w.open_url_in("https://example.com/?q=a b", "Google Chrome")
    script, env = seen[0]
    assert env == {"JC_APP": "chrome.exe", "JC_ARG": "https://example.com/?q=a b"} and "-ArgumentList" in script



START_APPS = [{"Name": "Battle.net", "AppID": "{7C5A40EF}\\Battle.net\\Battle.net Launcher.exe"},
              {"Name": "Call of Duty", "AppID": "battlenet://game/auks"},
              {"Name": "Visual Studio Code", "AppID": "Microsoft.VisualStudioCode"},
              {"Name": "Steam", "AppID": "{7C5A40EF}\\Steam\\steam.exe"}]


def test_apps_are_found_like_the_start_menu_does():
    # Live 2026-11-19: "Call of Duty: Warzone" and "Battle.net" didn't open on the PC.
    from jc_client.skills.windows import pick_start_app
    assert pick_start_app("Call of Duty: Warzone", START_APPS)["Name"] == "Call of Duty"
    assert pick_start_app("battle.net", START_APPS)["Name"] == "Battle.net"
    assert pick_start_app("visual studio code", START_APPS)["Name"] == "Visual Studio Code"
    assert pick_start_app("photoshop", START_APPS) is None


def test_no_nickname_table_decides_what_an_app_is():
    # His ask 2026-11-20: nothing hard-coded per app. A nickname the Start menu doesn't list isn't guessed here —
    # the planner sees the installed apps and picks the real name.
    from jc_client.skills import windows
    assert windows.pick_start_app("warzone", START_APPS) is None
    assert not hasattr(windows, "_APP_ALIASES") and not hasattr(windows, "launcher_of")


def test_a_link_entry_names_the_app_windows_opens_it_with():
    # A Start entry that is a link (a game's page in its launcher) opens in whatever app Windows has for that link.
    from jc_client.skills.windows import launch_argv, link_handler
    cmd = {"battlenet": '"C:\\Program Files (x86)\\Battle.net\\Battle.net.exe" --uri="%1"',
           "steam": '"C:\\Program Files (x86)\\Steam\\steam.exe" -- "%1"'}
    assert link_handler("battlenet://game/auks", query=cmd.get) == "Battle.net"
    assert link_handler("steam://rungameid/10", query=cmd.get) == "steam"
    assert link_handler("epic://x", query=cmd.get) == ""
    assert link_handler("Microsoft.VisualStudioCode", query=cmd.get) == ""
    assert launch_argv({"Name": "Call of Duty", "AppID": "battlenet://game/auks"}) == ["battlenet://game/auks"]
    assert launch_argv({"Name": "Visual Studio Code", "AppID": "Microsoft.VisualStudioCode"}) == \
        ["shell:AppsFolder\\Microsoft.VisualStudioCode"]


def test_an_app_that_isnt_installed_says_what_is(monkeypatch):
    from jc_client.skills import windows

    def fail(script, **kw):
        raise RuntimeError("Start-Process : This command cannot be run")
    monkeypatch.setattr(windows, "_start_apps", lambda: START_APPS)
    monkeypatch.setattr(windows, "_ps", fail)
    out = windows.open_app("warzone")
    assert out["ok"] is False and "warzone" in out["error"]
    assert out["apps"] == ["Battle.net", "Call of Duty", "Visual Studio Code", "Steam"]


def test_the_installed_apps_are_listed():
    from jc_client.skills.common import installed_app_names
    assert installed_app_names("win32", start_apps=lambda: START_APPS + [{"Name": "Steam", "AppID": "x"}]) == \
        ["Battle.net", "Call of Duty", "Visual Studio Code", "Steam"]


def test_the_macs_installed_apps_come_from_its_app_folders(tmp_path):
    from jc_client.skills.common import installed_app_names
    (tmp_path / "Safari.app").mkdir()
    (tmp_path / "Utilities").mkdir()
    (tmp_path / "Utilities" / "Terminal.app").mkdir()
    (tmp_path / "notes.txt").write_text("x")
    assert installed_app_names("darwin", app_dirs=[tmp_path]) == ["Safari", "Terminal"]


def test_a_locked_desktop_is_seen():
    from jc_client.skills.common import desktop_locked
    assert desktop_locked(open_desktop=lambda: None, name_of=lambda h: "") is True          # can't open it: locked
    assert desktop_locked(open_desktop=lambda: 7, name_of=lambda h: "Winlogon") is True
    assert desktop_locked(open_desktop=lambda: 7, name_of=lambda h: "Default") is False



def test_the_session_lock_state_comes_from_windows():
    from jc_client.skills.common import session_locked
    assert session_locked(flags=lambda: 0) is True          # WTS_SESSIONSTATE_LOCK
    assert session_locked(flags=lambda: 1) is False         # WTS_SESSIONSTATE_UNLOCK
    assert session_locked(flags=lambda: None) is None       # can't tell: the desktop check decides


def test_the_session_info_is_read_at_the_right_offsets():
    # Live 2026-11-20: WTSINFOEXW pads 4 bytes after Level (the union holds 8-byte times), so reading the 4th int
    # took SessionState (Active = 0) for the flags and said "locked" on an active session.
    from jc_client.skills.common import _flags_from
    assert _flags_from([1, 0, 4, 0, 1]) == 1        # level 1, pad, session 4, WTSActive, UNLOCK
    assert _flags_from([1, 0, 4, 0, 0]) == 0        # locked
    assert _flags_from([2, 0, 4, 0, 1]) is None     # unknown level
    assert _flags_from([1, 0, 4, 0, -1]) is None    # WTS_SESSIONSTATE_UNKNOWN
