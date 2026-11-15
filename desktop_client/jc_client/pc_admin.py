"""PC admin actions (contract C6, Pranav's call: phone Face ID + UAC).

The Windows app asks over the link (``admin_run``). jc-client sends the request up the
bridge; the server asks his iPhone for Face ID and answers with ``pc_admin_decision``.
Only an approval launches the command elevated (``runas``), so Windows still shows its own
UAC prompt. There's no always-elevated helper. No answer in ``timeout`` counts as denied.
"""
from __future__ import annotations

import logging
import sys
import threading
import uuid
from typing import Callable

log = logging.getLogger(__name__)


def platform_name(platform: str | None = None) -> str:
    p = platform or sys.platform
    if p == "darwin":
        return "macos"
    if p == "win32":
        return "windows"
    return "linux"


def app_exe_path(localappdata: str | None = None) -> str:
    """Where the Jarvis Windows app is installed (C5): %LOCALAPPDATA%\\Programs\\Jarvis\\app\\Jarvis.exe."""
    import ntpath
    import os
    base = localappdata if localappdata is not None else os.environ.get("LOCALAPPDATA", "")
    return ntpath.join(base, "Programs", "Jarvis", "app", "Jarvis.exe") if base else ""


def is_jarvis_app(pid: int, exe_of: Callable[[int], str] | None = None, expected: str | None = None) -> bool:
    """Whether the link peer is the installed Jarvis Windows app (the only one allowed to ask
    for admin actions: the endpoint token alone is readable by any process of this user)."""
    if not pid:
        return False
    if exe_of is None:
        def exe_of(p: int) -> str:
            import psutil
            return psutil.Process(p).exe()
    import ntpath
    want = expected if expected is not None else app_exe_path()
    if not want:
        return False
    try:
        got = str(exe_of(int(pid)) or "")
    except Exception:  # noqa: BLE001
        return False
    # The whole path, not its ending: a copy under %TEMP%\\programs\\jarvis\\app\\ must not pass.
    return ntpath.normcase(ntpath.normpath(got)) == ntpath.normcase(ntpath.normpath(want))


def win_elevate(command: str) -> int:
    """Start ``command`` elevated through cmd.exe; Windows shows UAC. >32 = started."""
    import ctypes
    # /s /c "…": cmd keeps the command's own quotes ("C:\\Program Files\\x.exe" "arg").
    return int(ctypes.windll.shell32.ShellExecuteW(None, "runas", "cmd.exe", '/s /c "' + command + '"', None, 1))


class PcAdmin:
    def __init__(self, send_up: Callable[[dict], bool], elevate: Callable[[str], int],
                 timeout: float = 120.0) -> None:
        self._send_up = send_up
        self._elevate = elevate
        self._timeout = timeout
        self._lock = threading.Lock()
        self._waiting: dict[str, list] = {}   # request id -> [Event, approved]

    def request(self, command: str, why: str, device_id: str = "") -> dict:
        command = (command or "").strip()
        if not command:
            return {"ok": False, "status": "denied", "error": "no command"}
        rid = uuid.uuid4().hex
        slot = [threading.Event(), False]
        with self._lock:
            self._waiting[rid] = slot
        try:
            sent = self._send_up({"type": "event", "name": "pc_admin_request",
                                  "data": {"request_id": rid, "command": command, "why": str(why or "")}})
            if not sent:
                return {"ok": False, "status": "denied", "error": "offline"}
            if not slot[0].wait(self._timeout):
                return {"ok": False, "status": "timeout"}
        finally:
            with self._lock:
                self._waiting.pop(rid, None)
        if not slot[1]:
            return {"ok": False, "status": "denied"}
        log.info("admin action approved on the phone: starting it elevated")
        try:
            code = self._elevate(command)
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "status": "approved", "error": f"couldn't elevate: {exc}"}
        if code <= 32:
            return {"ok": False, "status": "approved", "error": f"couldn't elevate (code {code}; UAC cancelled?)"}
        return {"ok": True, "status": "approved"}

    def decision(self, frame: dict) -> None:
        with self._lock:
            slot = self._waiting.get(str(frame.get("request_id") or ""))
        if slot is None:
            return
        slot[1] = bool(frame.get("approved"))
        slot[0].set()
