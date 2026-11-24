"""This computer's stable hardware id, hashed (2026-11-24): sent when pairing and in the register frame so the server
keeps ONE device record per computer however often it re-pairs. Before, every re-pair made a new record: the PC
card showed a stale second PC, the power button lost its link and the unlock permission no longer matched.

Windows: MachineGuid; macOS: IOPlatformUUID; Linux: /etc/machine-id. Only a salted SHA-256 of it is sent."""
from __future__ import annotations

import hashlib
import re
import subprocess
import sys
from pathlib import Path


def _raw() -> tuple:
    """(kind, raw id); raw is "" when the system won't say."""
    try:
        if sys.platform == "win32":
            import winreg
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Cryptography", 0,
                                winreg.KEY_READ | getattr(winreg, "KEY_WOW64_64KEY", 0)) as key:
                return "win", str(winreg.QueryValueEx(key, "MachineGuid")[0] or "")
        if sys.platform == "darwin":
            out = subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True,
                                 text=True, timeout=5).stdout
            m = re.search(r'"IOPlatformUUID" = "([^"]+)"', out or "")
            return "mac", m.group(1) if m else ""
        return "linux", Path("/etc/machine-id").read_text(encoding="utf-8").strip()
    except Exception:  # noqa: BLE001 — no id: the server just can't match a re-pair
        return ("win" if sys.platform == "win32" else "mac" if sys.platform == "darwin" else "linux"), ""


def machine_id() -> str:
    """"win-…" / "mac-…" / "linux-…" + 32 hex chars, stable for this computer; "" when unknown."""
    kind, raw = _raw()
    if not raw:
        return ""
    return f"{kind}-" + hashlib.sha256(f"jarvis-machine:{raw}".encode()).hexdigest()[:32]
