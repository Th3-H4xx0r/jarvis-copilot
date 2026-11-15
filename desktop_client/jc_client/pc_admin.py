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


def win_elevate(command: str) -> int:
    """Start ``command`` elevated through cmd.exe; Windows shows UAC. >32 = started."""
    import ctypes
    return int(ctypes.windll.shell32.ShellExecuteW(None, "runas", "cmd.exe", "/c " + command, None, 1))


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
