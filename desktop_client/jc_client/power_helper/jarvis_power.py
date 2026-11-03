"""jarvis-power: the root helper behind keep-awake and Wake Mac.

Installed by jc_client/power_install.py as /Library/PrivilegedHelperTools/
com.jarviscopilot.power.py and run by launchd as root with /usr/bin/python3. It
does only what needs root, on request from jc-client over a Unix socket that
only its owner (the Mac's user) can open:

    {"op": "hold", "on": bool}      pmset -a disablesleep 1|0 (lid shut included)
    {"op": "heartbeat"}             the holder is still alive
    {"op": "sleepnow"}              pmset sleepnow
    {"op": "wake_at", "ts": epoch}  one timer wake (replaces the previous one)
    {"op": "cancel_wake"}
    {"op": "status"}
    -> {"ok": bool, "held": bool, "wake_at": epoch | null}

A hold with no heartbeat for WATCHDOG seconds is released, and every start
resets disablesleep, so a crash can never leave the Mac unable to sleep.
Standalone on purpose: stdlib only, nothing from jc_client.
"""
from __future__ import annotations

import json
import os
import socketserver
import subprocess
import sys
import threading
import time
from typing import Callable, List, Optional

WATCHDOG = 35.0
SOCKET_PATH = "/var/run/com.jarviscopilot.power.sock"


def wake_stamp(ts: float) -> str:
    """pmset's schedule date: local time, MM/dd/yy HH:mm:ss."""
    return time.strftime("%m/%d/%y %H:%M:%S", time.localtime(ts))


class HelperState:
    def __init__(self, run: Callable[[List[str]], int], clock: Callable[[], float] = time.time) -> None:
        self._run = run
        self._clock = clock
        self._lock = threading.Lock()
        self.held = False
        self.wake_at: Optional[float] = None
        self._beat = clock()
        self._run(["pmset", "-a", "disablesleep", "0"])

    def _set(self, on: bool) -> None:
        self._run(["pmset", "-a", "disablesleep", "1" if on else "0"])
        self.held = on

    def _cancel(self) -> None:
        if self.wake_at is not None:
            self._run(["pmset", "schedule", "cancel", "wake", wake_stamp(self.wake_at)])
            self.wake_at = None

    def _reply(self) -> dict:
        return {"ok": True, "held": self.held, "wake_at": self.wake_at}

    def handle(self, req: dict) -> dict:
        op = req.get("op")
        now = self._clock()
        with self._lock:
            if op == "hold":
                self._beat = now
                on = bool(req.get("on"))
                if on != self.held:
                    self._set(on)
            elif op == "heartbeat":
                self._beat = now
            elif op == "sleepnow":
                self._run(["pmset", "sleepnow"])
            elif op == "wake_at":
                try:
                    ts = float(req.get("ts"))
                except (TypeError, ValueError):
                    return {"ok": False, "error": "bad ts"}
                if ts <= now:
                    return {"ok": False, "error": "wake time has passed"}
                self._cancel()
                self._run(["pmset", "schedule", "wake", wake_stamp(ts)])
                self.wake_at = ts
            elif op == "cancel_wake":
                self._cancel()
            elif op != "status":
                return {"ok": False, "error": "unknown op"}
            return self._reply()

    def tick(self) -> None:
        now = self._clock()
        with self._lock:
            if self.held and now - self._beat > WATCHDOG:
                self._set(False)
            if self.wake_at is not None and self.wake_at < now:
                self.wake_at = None    # it fired (or the Mac was awake): nothing to cancel


def _pmset(argv: List[str]) -> int:
    return subprocess.run(["/usr/bin/" + argv[0]] + argv[1:], capture_output=True, timeout=20).returncode


def serve(owner_uid: int, path: str = SOCKET_PATH) -> None:
    state = HelperState(_pmset)

    class Handler(socketserver.StreamRequestHandler):
        def handle(self) -> None:
            for raw in self.rfile:
                try:
                    req = json.loads(raw.decode("utf-8", "replace"))
                    reply = state.handle(req) if isinstance(req, dict) else {"ok": False, "error": "bad request"}
                except ValueError:
                    reply = {"ok": False, "error": "bad json"}
                self.wfile.write((json.dumps(reply) + "\n").encode())
                self.wfile.flush()

    class Server(socketserver.ThreadingUnixStreamServer):
        daemon_threads = True

    if os.path.exists(path):
        os.unlink(path)
    old = os.umask(0o177)
    try:
        server = Server(path, Handler)
    finally:
        os.umask(old)
    os.chown(path, owner_uid, -1)
    os.chmod(path, 0o600)

    def ticker() -> None:
        while True:
            time.sleep(5)
            state.tick()

    threading.Thread(target=ticker, daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    if os.geteuid() != 0 or len(sys.argv) != 3 or sys.argv[1] != "--uid":
        sys.exit("usage (as root): jarvis_power.py --uid <owner uid>")
    serve(int(sys.argv[2]))
