"""Client for the Jarvis helper's pipe ``\\\\.\\pipe\\JarvisUnlock`` (W4): one admin_run request line, one
reply line. The helper checks his signed Face ID approval covers exactly this command before running it
elevated; nothing here can widen that."""
from __future__ import annotations

import json
import threading
import time

PIPE_PATH = r"\\.\pipe\JarvisUnlock"
_NO_HELPER = "The Jarvis helper isn't running on this PC. Reinstall it in Jarvis Settings → PC power."


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
              connect_wait_s: float = 5.0) -> dict:
    opener = opener or _open_pipe
    line = json.dumps({"admin_run": {"command": command, "nonce": nonce, "ts": ts, "signature": signature,
                                     "timeout_s": int(timeout_s)}}) + "\n"
    deadline = time.monotonic() + connect_wait_s
    while True:
        try:
            pipe = opener(PIPE_PATH)
            break
        except FileNotFoundError:
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
