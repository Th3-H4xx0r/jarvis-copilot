"""Jarvis on the PC before sign-in (spec docs/superpowers/specs/2026-11-23-pc-boot-client-design.md).

A second jc-client starts at boot from the ``\\JarvisCopilot\\jc-client-boot`` task, as him (S4U: no stored password),
so the PC is online in Jarvis at the sign-in screen. It offers only what works without his desktop (status, power
frames, the wake check-in, sign in), signs him in through the JarvisUnlock service (which checks his Face ID itself:
there's no Jarvis app yet), and steps aside once his Windows session exists; the normal client (the logon task)
then takes over. The normal client also stops a boot instance it finds, so the two never share the device link.
"""
from __future__ import annotations

import ctypes
import logging
import os
import sys
import time
from pathlib import Path
from typing import Callable, Iterable, Optional

log = logging.getLogger(__name__)

ENV = "JC_BOOT_MODE"
# Skills that work in session 0, before he signs in. Everything else needs his desktop.
BOOT_SKILLS = frozenset({"screen_locked", "wol_send"})
HANDOVER_EVERY_S = 5.0


def is_boot() -> bool:
    return os.environ.get(ENV) == "1"


def filter_manifest(manifest: list) -> list:
    return [m for m in manifest if (m or {}).get("name") in BOOT_SKILLS]


def _wts_sessions() -> list:
    """(session id, user name) for every Windows session ("" = nobody signed in there)."""
    if sys.platform != "win32":
        return []
    wts = ctypes.windll.wtsapi32

    class WTS_SESSION_INFOW(ctypes.Structure):
        _fields_ = [("SessionId", ctypes.c_ulong), ("pWinStationName", ctypes.c_wchar_p), ("State", ctypes.c_int)]

    p = ctypes.POINTER(WTS_SESSION_INFOW)()
    count = ctypes.c_ulong(0)
    if not wts.WTSEnumerateSessionsW(None, 0, 1, ctypes.byref(p), ctypes.byref(count)):
        return []
    out = []
    try:
        for i in range(count.value):
            sid = p[i].SessionId
            buf, size = ctypes.c_wchar_p(), ctypes.c_ulong(0)
            name = ""
            if wts.WTSQuerySessionInformationW(None, sid, 5, ctypes.byref(buf), ctypes.byref(size)):   # WTSUserName
                name = buf.value or ""
                wts.WTSFreeMemory(buf)
            out.append((int(sid), name))
    finally:
        wts.WTSFreeMemory(p)
    return out


def _me() -> str:
    return os.environ.get("USERNAME") or os.environ.get("USER") or ""


def user_signed_in(user: str = "", sessions: Callable[[], Iterable[tuple]] = _wts_sessions) -> bool:
    """He has a Windows session (console or Remote Desktop, active or disconnected): the normal client runs there."""
    want = (user or _me()).lower()
    return bool(want) and any((name or "").lower() == want for _sid, name in sessions())


class Handover:
    """Boot instance: exit once his session exists (the logon task starts the normal client in it)."""

    def __init__(self, user: str = "", sessions: Callable[[], Iterable[tuple]] = _wts_sessions,
                 exit: Callable[[], None] = lambda: os._exit(0)) -> None:
        self._user, self._sessions, self._exit = user, sessions, exit

    def tick(self) -> bool:
        if user_signed_in(self._user, self._sessions):
            log.info("boot mode: he signed in; handing over to the normal client")
            self._exit()
            return True
        return False


def watch(stop_pid_file: Optional[Path] = None) -> None:
    """Run the hand-over check every HANDOVER_EVERY_S (boot instance only)."""
    import threading

    def exit_now() -> None:
        if stop_pid_file is not None:
            try:
                stop_pid_file.unlink()
            except OSError:
                pass
        os._exit(0)

    h = Handover(exit=exit_now)

    def loop() -> None:
        while True:
            try:
                h.tick()
            except Exception:  # noqa: BLE001
                log.debug("boot hand-over check failed", exc_info=True)
            time.sleep(HANDOVER_EVERY_S)

    threading.Thread(target=loop, name="jc-boot-handover", daemon=True).start()


def stop_boot_instance(pid_file: Path, *, is_running: Callable[[int], bool], kill: Callable[[int], None],
                       wait_s: float = 10.0) -> bool:
    """Normal client starting: stop a boot instance still holding the link. True when one was stopped."""
    try:
        pid = int(Path(pid_file).read_text().strip())
    except (OSError, ValueError):
        return False
    if not is_running(pid):
        try:
            Path(pid_file).unlink()
        except OSError:
            pass
        return False
    try:
        kill(pid)
    except OSError:
        log.debug("couldn't stop the boot instance %s", pid, exc_info=True)
    deadline = time.monotonic() + wait_s
    while is_running(pid) and time.monotonic() < deadline:
        time.sleep(0.1)
    try:
        Path(pid_file).unlink()
    except OSError:
        pass
    log.info("stopped the boot instance (pid %s) to take over", pid)
    return True
