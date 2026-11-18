"""Game mode (contract C3): computer control and capture pause while Pranav plays."""
import pytest

from jc_client import game_mode, skills
from jc_client.game_mode import OFF, ForegroundInfo, GameMode, GameState, evaluate

MON = (0, 0, 2560, 1440)
GAMES = set(game_mode.DEFAULT_ANTICHEAT_GAMES)


def fg(exe="notgame.exe", rect=MON, monitor=MON, shell=False):
    return ForegroundInfo(hwnd=1, exe=exe, rect=rect, monitor=monitor, is_shell=shell)


def test_fullscreen_foreground_is_game():
    assert evaluate(fg("notgame.exe"), set(), GAMES) == GameState(True, "fullscreen notgame.exe", False)
    assert evaluate(fg("eldenring.exe"), {"eldenring.exe"}, GAMES) == GameState(True, "fullscreen eldenring.exe", True)


def test_fullscreen_on_secondary_monitor():
    second = (2560, 0, 5120, 1440)
    assert evaluate(fg(rect=second, monitor=second), set(), GAMES).on


def test_desktop_shell_fullscreen_is_not_game():
    assert evaluate(fg("explorer.exe", shell=True), set(), GAMES) == OFF


def test_windows_own_fullscreen_hosts_are_not_games():
    # Live 2026-11-17: an idle PC reported "in a game (fullscreen textinputhost.exe)" and refused
    # every look — that's the touch-keyboard / IME host, not a game.
    for exe in ("TextInputHost.exe", "LockApp.exe", "SearchHost.exe", "StartMenuExperienceHost.exe",
                "ShellExperienceHost.exe", "LogonUI.exe"):
        assert evaluate(fg(exe), set(), GAMES) == OFF, exe
    # A real anti-cheat game still counts even if one of those is in front.
    assert evaluate(fg("TextInputHost.exe"), {"valorant-win64-shipping.exe"}, GAMES).on


def test_windowed_app_is_not_game():
    assert evaluate(fg(rect=(100, 100, 1200, 900)), set(), GAMES) == OFF


def test_no_foreground_is_not_game():
    assert evaluate(None, set(), GAMES) == OFF


def test_anticheat_game_process_on_even_in_background():
    st = evaluate(fg(rect=(0, 0, 800, 600)), {"valorant-win64-shipping.exe", "chrome.exe"}, GAMES)
    assert st == GameState(True, "valorant-win64-shipping.exe is running", True)


def test_resident_anticheat_service_alone_is_off():
    assert evaluate(fg(rect=(0, 0, 800, 600)), {"vgc.exe", "easyanticheat.exe", "beservice.exe"}, GAMES) == OFF


def test_on_change_fires_once_per_transition():
    seen = []
    state = {"fg": fg(rect=(0, 0, 10, 10))}
    gm = GameMode(lambda: state["fg"], lambda: set(), GAMES, seen.append)
    gm.poll_once()
    gm.poll_once()
    assert seen == []
    state["fg"] = fg()
    gm.poll_once()
    gm.poll_once()
    assert seen == [GameState(True, "fullscreen notgame.exe", False)]
    state["fg"] = fg(rect=(0, 0, 10, 10))
    gm.poll_once()
    assert seen[-1] == OFF and len(seen) == 2


def test_refusal_text_exact():
    st = GameState(True, "fullscreen eldenring.exe", True)
    assert game_mode.refusal(st) == {
        "ok": False, "game_mode": True,
        "error": "Pranav is in a game (fullscreen eldenring.exe); computer control is paused until he leaves it."}


@pytest.fixture
def in_game():
    game_mode.set_current(lambda: GameState(True, "fullscreen eldenring.exe", True))
    yield
    game_mode.set_current(None)


def test_invoke_refuses_guarded_skill_in_game(in_game):
    skills.load_all()
    assert skills.has_skill("mouse_click")
    out = skills.invoke("mouse_click", {})
    assert out == game_mode.refusal(game_mode.current())


def test_invoke_allows_unguarded_skill_in_game(in_game):
    skills.load_all()
    out = skills.invoke("system_info", {})
    assert not (isinstance(out, dict) and out.get("game_mode"))


def test_current_is_off_without_a_game_mode():
    game_mode.set_current(None)
    assert game_mode.current() == OFF


def test_full_screen_explorer_and_snipping_tool_are_not_games():
    for exe in ("explorer.exe", "SnippingTool.exe"):
        assert evaluate(fg(exe), set(), GAMES) == OFF, exe
