"""Setting up PC lighting on the PC, one step at a time (the phone shows them as a checklist).

openrgb   install OpenRGB (Face ID + UAC, which also stops SignalRGB's service), run it headless at login
signalrgb quit SignalRGB and remove only its own start-at-login (never uninstalls it)
driver    PawnIO only when a controller sits on SMBus (his board is USB, so skipped there)
detect    OpenRGB sees at least one lighting controller
cost      whether animated effects should freeze while a game runs (SMBus, or > 1 % of a core)
calibrate finished on the iPhone (the server reports it)
"""
from __future__ import annotations

import re
import time
from typing import Any, Callable

OPENRGB_EXE = r"C:\Program Files\OpenRGB\OpenRGB.exe"
RUN_KEY = r"HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
SERVICE = "SignalRgbService"
COST_LIMIT = 1.0          # % of one core
PAWNIO_MIN = (2, 1, 0)    # FACEIT blocks older PawnIO

INSTALL = (f"winget install --id OpenRGB.OpenRGB --exact --silent --accept-package-agreements "
           f"--accept-source-agreements; $c = $LASTEXITCODE; "
           f"Stop-Service {SERVICE} -Force -ErrorAction SilentlyContinue; "
           f"Set-Service {SERVICE} -StartupType Manual -ErrorAction SilentlyContinue; exit $c")
STOP_SERVICE = f"Stop-Service {SERVICE} -Force -ErrorAction SilentlyContinue; Set-Service {SERVICE} -StartupType Manual"
INSTALLED = f"Test-Path '{OPENRGB_EXE}'"
AUTOSTART = (f"Set-ItemProperty -Path '{RUN_KEY}' -Name OpenRGB "
             f"-Value '\"{OPENRGB_EXE}\" --server --noautoconnect'")
LAUNCH = (f"if (-not (Get-Process OpenRGB -ErrorAction SilentlyContinue)) {{ Start-Process -FilePath '{OPENRGB_EXE}' "
          f"-ArgumentList '--server','--noautoconnect' -WindowStyle Hidden }}")
QUIT_SIGNALRGB = (f"Stop-Process -Name SignalRgb,SignalRgbLauncher -Force -ErrorAction SilentlyContinue; "
                  f"Remove-ItemProperty -Path '{RUN_KEY}' -Name SignalRgb -ErrorAction SilentlyContinue; "
                  f"(Get-Service {SERVICE} -ErrorAction SilentlyContinue).Status")
PAWNIO_VERSION = (r"(Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*, "
                  r"HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* "
                  r"-ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'PawnIO' } "
                  r"| Select-Object -First 1).DisplayVersion")
PAWNIO_UPDATE = ("winget install --id namazso.PawnIO --exact --silent --accept-package-agreements "
                 "--accept-source-agreements")

STEPS = ("openrgb", "signalrgb", "driver", "detect", "cost", "calibrate")


def _step(step: str, state: str, detail: str, **extra) -> dict:
    return {"id": step, "state": state, "detail": detail, **extra}


def _smbus(controllers: list) -> bool:
    return any(re.match(r"\s*(i2c|smbus)", str(c.get("location") or ""), re.I) for c in controllers)


def _admin_ok(res: dict) -> tuple[bool, str]:
    if not res.get("ok"):
        return False, f"Not done: {res.get('error') or res.get('status') or 'Face ID was not given'}"
    if res.get("exit_code") not in (0, None):
        return False, (res.get("output") or f"exit code {res.get('exit_code')}")[-400:]
    return True, ""


def _version(text: str) -> tuple:
    nums = [int(x) for x in re.findall(r"\d+", text or "")[:3]]
    return tuple(nums + [0] * (3 - len(nums))) if nums else ()


def _default_admin(command: str, why: str = "", timeout_s: int = 600, elevated: bool = True) -> dict:
    from jc_client.skills.pc_it import admin_run
    return admin_run(command, why=why, timeout_s=timeout_s, elevated=elevated)


def _default_shell(command: str, timeout_s: int = 120) -> dict:
    from jc_client.skills.pc_it import run_powershell
    return run_powershell(command, timeout_s)


def _default_game():
    from jc_client import game_mode
    return game_mode.current()


def run_step(step: str, sensor_driver: bool, admin_run: Callable[..., dict] = _default_admin,
             shell: Callable[..., dict] = _default_shell, engine: Any = None,
             game_state: Callable[[], Any] = _default_game, sleep: Callable[[float], None] = time.sleep) -> dict:
    if step not in STEPS:
        return _step(step, "failed", f"Unknown setup step {step!r}")
    if step == "calibrate":
        return _step(step, "todo", "Finish on your iPhone: tap each part as it lights up")
    if getattr(game_state(), "on", False):
        return _step(step, "failed", "Finish your game first — setup never runs while you play")
    if engine is None:
        return _step(step, "failed", "PC lighting isn't running in jc-client")

    if step == "openrgb":
        installed = (shell(INSTALLED, 30).get("stdout") or "").strip().lower() == "true"
        if not installed:
            ok, why = _admin_ok(admin_run(INSTALL, why="Install OpenRGB so Jarvis can drive your PC's lights "
                                                     "(and stop SignalRGB's service)", timeout_s=900))
            if not ok:
                return _step(step, "failed", why)
        shell(AUTOSTART, 30)
        shell(LAUNCH, 30)
        for _ in range(10):
            engine.reconnect()
            if engine.status().get("controllers"):
                return _step(step, "done", "OpenRGB is installed and running at login")
            sleep(1.0)
        return _step(step, "failed", engine.status().get("error") or "OpenRGB started but isn't answering on port 6742")

    if step == "signalrgb":
        status = (shell(QUIT_SIGNALRGB, 60).get("stdout") or "").strip()
        if status.lower() == "running":
            ok, why = _admin_ok(admin_run(STOP_SERVICE, why="Stop SignalRGB's service so only OpenRGB drives the lights",
                                          timeout_s=120))
            if not ok:
                return _step(step, "failed", why)
        return _step(step, "done", "SignalRGB is closed and won't start at login (still installed)")

    controllers = engine.status().get("controllers") or []
    if step == "driver":
        if not _smbus(controllers):
            return _step(step, "skipped", "Not needed: your lights are on USB")
        if not sensor_driver:
            return _step(step, "failed", "Turn on PC Stats' sensor driver (PawnIO) — your lights need it")
        version = _version(shell(PAWNIO_VERSION, 30).get("stdout") or "")
        if version and version >= PAWNIO_MIN:
            return _step(step, "done", "PawnIO is up to date")
        ok, why = _admin_ok(admin_run(PAWNIO_UPDATE, why="Update PawnIO so anti-cheat accepts it", timeout_s=600))
        return _step(step, "done" if ok else "failed", "PawnIO updated" if ok else why)

    if step == "detect":
        if not controllers:
            return _step(step, "failed", "OpenRGB found no lights — is SignalRGB still holding them?")
        names = ", ".join(f"{c.get('name')} ({len(c.get('zones') or [])} zones)" for c in controllers)
        return _step(step, "done", names)

    # cost
    if _smbus(controllers):
        return _step(step, "done", "Effects pause while you play: SMBus lighting can stutter games",
                     still_in_games=True)
    cpu = engine.measure(10.0)
    if cpu > COST_LIMIT:
        return _step(step, "done", f"Effects pause while you play: they used {cpu:.1f}% of a core",
                     still_in_games=True)
    return _step(step, "done", f"Effects keep running in games: {cpu:.1f}% of a core", still_in_games=False)
