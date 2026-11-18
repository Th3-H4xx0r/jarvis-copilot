"""Client for the Jarvis helper's pipe ``\\\\.\\pipe\\JarvisUnlock`` (W4): one admin_run request line, one
reply line. The helper checks his signed Face ID approval covers exactly this command before running it
elevated; nothing here can widen that."""
from __future__ import annotations

import json
import subprocess
import threading
import time
from typing import Callable, Optional

PIPE_PATH = r"\\.\pipe\JarvisUnlock"
_NO_HELPER = "The Jarvis helper isn't running on this PC. Reinstall it in Jarvis Settings → PC power."


def _start_service() -> bool:
    """Start a stopped JarvisUnlock service (the installer lets his account start it)."""
    try:
        r = subprocess.run(["sc.exe", "start", "JarvisUnlock"], capture_output=True, text=True, timeout=15,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0 or "1056" in (r.stdout + r.stderr)   # 1056: already running


def _open_pipe(path: str):
    return open(path, "r+b", buffering=0)


def _read_line(pipe, timeout: float):
    box: dict = {}

    def read():
        buf = b""
        try:
            while b"\n" not in buf:
                chunk = pipe.read(65536)
                if not chunk:
                    break
                buf += chunk
        except Exception as exc:  # noqa: BLE001
            box["error"] = exc
        box["line"] = buf.split(b"\n", 1)[0]

    reader = threading.Thread(target=read, name="jc-helper-pipe", daemon=True)
    reader.start()
    reader.join(timeout)
    return None if reader.is_alive() else box.get("line")


def admin_run(command: str, nonce: str, ts, signature: str, timeout_s: int, *, opener=None,
              connect_wait_s: float = 5.0, start_helper: Optional[Callable[[], bool]] = None) -> dict:
    opener = opener or _open_pipe
    start_helper = start_helper or _start_service
    started = False
    line = json.dumps({"admin_run": {"command": command, "nonce": nonce, "ts": ts, "signature": signature,
                                     "timeout_s": int(timeout_s)}}) + "\n"
    deadline = time.monotonic() + connect_wait_s
    while True:
        try:
            pipe = opener(PIPE_PATH)
            break
        except FileNotFoundError:
            # No pipe: the helper service is stopped (live 2026-11-18). Start it once, then give it a moment.
            if not started:
                started = True
                if start_helper():
                    deadline = time.monotonic() + max(connect_wait_s, 5.0)
                    continue
            if started and time.monotonic() < deadline:
                time.sleep(0.25)
                continue
            return {"ok": False, "error": _NO_HELPER}
        except OSError as exc:   # every pipe instance busy (another request in flight): wait a moment
            if time.monotonic() >= deadline:
                return {"ok": False, "error": f"The Jarvis helper is busy ({exc})"}
            time.sleep(0.2)
    try:
        pipe.write(line.encode("utf-8"))
        raw = _read_line(pipe, int(timeout_s) + 15)
    finally:
        try:
            pipe.close()
        except Exception:  # noqa: BLE001
            pass
    if raw is None:
        return {"ok": False, "error": "The Jarvis helper didn't answer in time"}
    try:
        reply = json.loads(raw.decode("utf-8"))
    except ValueError:
        reply = None
    if not isinstance(reply, dict):
        return {"ok": False, "error": "The Jarvis helper sent an unreadable reply"}
    if reply.get("ok") is not True:
        return {"ok": False, "error": str(reply.get("error") or "The Jarvis helper refused")}
    return reply
