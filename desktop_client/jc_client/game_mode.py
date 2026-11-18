"""Game mode (contract C3 in docs/superpowers/plans/2026-11-15-windows-client-00-index.md).

On the PC, while Pranav plays, Jarvis must not draw over the game, take focus, cost frames or
touch an anti-cheat game. jc-client owns the one signal so the skills (here) and the Windows
app (via the ``game_mode`` link broadcast) agree:

* on when the foreground window covers its whole monitor (and isn't the desktop), or
* when a process of an installed anti-cheat game runs (``anticheat`` true: capture and input
  stay off even with the game in the background). A resident anti-cheat driver or service
  alone (Vanguard loads at boot) never counts, or computer control would be dead all day.
"""
from __future__ import annotations

import logging
import sys
import threading
from dataclasses import dataclass
from typing import Callable, Iterable, Optional

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class GameState:
    on: bool
    reason: str
    anticheat: bool


OFF = GameState(False, "", False)


@dataclass(frozen=True)
class ForegroundInfo:
    hwnd: int
    exe: str
    rect: tuple
    monitor: tuple
    is_shell: bool


# Lowercase executable names of games that run kernel/user anti-cheat (Vanguard, EAC,
# BattlEye, Ricochet…). Extend with config `game_mode.anticheat_games`.
DEFAULT_ANTICHEAT_GAMES = frozenset({
    "valorant-win64-shipping.exe", "league of legends.exe", "fortniteclient-win64-shipping.exe",
    "r5apex.exe", "r5apex_dx12.exe", "rainbowsix.exe", "rainbowsix_be.exe", "eldenring.exe",
    "cod.exe", "destiny2.exe", "tslgame.exe",
})

GUARDED = frozenset({
    "ui_look", "ui_do", "mouse_position", "mouse_move", "mouse_click", "mouse_scroll", "mouse_drag",
    "mouse_button", "mouse_path", "type_text", "key_press", "key_hold", "key_release", "screenshot",
    "screen_highlight", "color_at", "wait_for_image",
})

_SHELL_CLASSES = frozenset({"Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"})
# Windows' own fullscreen hosts (touch keyboard / IME, lock and sign-in screens, Start, search):
# fullscreen, but never a game (an idle PC read as "in a game (fullscreen textinputhost.exe)").
_SYSTEM_HOSTS = frozenset({"textinputhost.exe", "lockapp.exe", "logonui.exe", "searchhost.exe", "searchapp.exe",
                           "startmenuexperiencehost.exe", "shellexperiencehost.exe", "explorer.exe",
                           "snippingtool.exe"})


def evaluate(fg: Optional[ForegroundInfo], procs: Iterable[str], anticheat_games: Iterable[str]) -> GameState:
    games = {g.lower() for g in anticheat_games}
    running = sorted(p for p in (x.lower() for x in procs) if p in games)
    full = (fg is not None and not fg.is_shell and fg.exe.lower() not in _SYSTEM_HOSTS
            and tuple(fg.rect) == tuple(fg.monitor))
    if full:
        exe = fg.exe.lower()
        return GameState(True, f"fullscreen {exe}", bool(running) or exe in games)
    if running:
        return GameState(True, f"{running[0]} is running", True)
    return OFF


def refusal(state: GameState) -> dict:
    return {"ok": False, "game_mode": True,
            "error": f"Pranav is in a game ({state.reason}); computer control is paused until he leaves it."}


class GameMode:
    """Polls the foreground every ``every`` s and the process list every ``proc_every`` s."""

    def __init__(self, foreground: Callable[[], Optional[ForegroundInfo]], processes: Callable[[], set],
                 anticheat_games: Iterable[str], on_change: Callable[[GameState], None], *,
                 every: float = 2.0, proc_every: float = 10.0) -> None:
        self._foreground = foreground
        self._processes = processes
        self._games = frozenset(g.lower() for g in anticheat_games)
        self._on_change = on_change
        self._every = every
        self._proc_every = proc_every
        self._procs: set = set()
        self._procs_age = float("inf")
        self._state = OFF
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def state(self) -> GameState:
        return self._state

    def poll_once(self) -> GameState:
        if self._procs_age >= self._proc_every:
            try:
                self._procs = set(self._processes())
            except Exception:  # noqa: BLE001
                log.debug("process scan failed", exc_info=True)
            self._procs_age = 0.0
        self._procs_age += self._every
        try:
            fg = self._foreground()
        except Exception:  # noqa: BLE001
            fg = None
        new = evaluate(fg, self._procs, self._games)
        if new != self._state:
            self._state = new
            log.info("game mode %s%s", "on: " if new.on else "off", new.reason)
            try:
                self._on_change(new)
            except Exception:  # noqa: BLE001
                log.debug("game mode on_change failed", exc_info=True)
        return new

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True, name="game-mode")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread = None

    def _loop(self) -> None:
        while not self._stop.is_set():
            self.poll_once()
            self._stop.wait(self._every)


_current: Optional[Callable[[], GameState]] = None


def set_current(state_fn: Optional[Callable[[], GameState]]) -> None:
    global _current
    _current = state_fn


def current() -> GameState:
    fn = _current
    if fn is None:
        return OFF
    try:
        return fn()
    except Exception:  # noqa: BLE001
        return OFF


# ── Windows probes ─────────────────────────────────────────────────────────────
def win_foreground() -> Optional[ForegroundInfo]:
    """The foreground window, its exe, its rect and its monitor's rect (Windows only)."""
    if sys.platform != "win32":
        return None
    import ctypes
    from ctypes import wintypes

    user32 = ctypes.windll.user32
    hwnd = user32.GetForegroundWindow()
    if not hwnd:
        return None
    cls = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, cls, 256)
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))

    class MONITORINFO(ctypes.Structure):
        _fields_ = [("cbSize", wintypes.DWORD), ("rcMonitor", wintypes.RECT),
                    ("rcWork", wintypes.RECT), ("dwFlags", wintypes.DWORD)]

    mon = user32.MonitorFromWindow(hwnd, 2)   # MONITOR_DEFAULTTONEAREST
    info = MONITORINFO()
    info.cbSize = ctypes.sizeof(MONITORINFO)
    user32.GetMonitorInfoW(mon, ctypes.byref(info))
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    exe = ""
    try:
        import psutil
        exe = psutil.Process(pid.value).name()
    except Exception:  # noqa: BLE001
        pass
    m = info.rcMonitor
    return ForegroundInfo(hwnd=int(hwnd), exe=exe,
                          rect=(rect.left, rect.top, rect.right, rect.bottom),
                          monitor=(m.left, m.top, m.right, m.bottom),
                          is_shell=cls.value in _SHELL_CLASSES)


def process_names() -> set:
    import psutil
    out = set()
    for p in psutil.process_iter(["name"]):
        name = p.info.get("name")
        if name:
            out.add(name.lower())
    return out
