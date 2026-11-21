"""Sunshine log watcher.

Tails Sunshine's log and turns its lines into events (stream_start / stream_stop /
device_connect), derives a lightweight "a stream is running" flag, and flags a
device_connect whose client id isn't in the known paired set. Unparseable lines
return None — the parser degrades, it never raises.

NOTE (verify live): the log line patterns below are representative; confirm them
against the user's Sunshine build and adjust _PATTERNS (one line each). Client
identity comes from the connect line's name (certs aren't in the log).
"""
from __future__ import annotations

import re
import threading
import time

# The strings Sunshine really writes (LizardByte/Sunshine src/stream.cpp + src/process.cpp,
# verified 2026-11-21). Connect/disconnect lines carry no names; the app appears as the
# command Sunshine runs, so the watcher maps it to the app's name via apps.json.
_PATTERNS = [
    (re.compile(r"CLIENT DISCONNECTED", re.I), "stream_stop"),
    (re.compile(r"CLIENT CONNECTED(?:\s*\[([^\]]+)\])?", re.I), "stream_start"),
    # "Executing [Desktop]" / "Executing: [cmd] in [dir]" / "Spawning [cmd] in [dir]".
    # "Executing Do Cmd: [..]" / "Executing Undo Cmd: [..]" (prep commands) don't match.
    (re.compile(r"(?:Executing|Spawning):?\s+\[([^\]]+)\]", re.I), "app_exec"),
    (re.compile(r"Launching\s*\[([^\]]+)\]", re.I), "app_exec"),
    (re.compile(r"Session (?:ended|terminated)", re.I), "stream_stop"),
]


def parse_log_line(line: str):
    """Return an event dict for a recognised line, else None (never raises)."""
    try:
        for rx, kind in _PATTERNS:
            m = rx.search(line)
            if not m:
                continue
            ev = {"kind": kind, "client": None, "app": None, "raw": line.strip()}
            grp = m.group(1) if m.groups() else None
            if kind == "stream_start":
                ev["client"] = grp
            elif kind == "app_exec":
                ev["app"] = grp
            return ev
    except Exception:
        return None
    return None


class SunshineWatcher:
    def __init__(self, client, known_certs, emit, log_path=None, interval=1.0, app_names=None):
        self._client = client
        self._app_names = dict(app_names or {})
        self._last_app = None
        self._known = set(known_certs or ())
        self._emit = emit
        self._log_path = log_path
        self._interval = interval
        self._live = {"active": False, "client": None, "app": None}
        self._stop = threading.Event()
        self._thread = None

    def set_known(self, known_certs):
        self._known = set(known_certs or ())

    def process_line(self, line: str):
        """An event to send up for a stream start/stop, else None. App launches are
        remembered (mapped command -> app name) and attached to the next stream start."""
        ev = parse_log_line(line)
        if ev is None:
            return None
        if ev["kind"] == "app_exec":
            cmd = ev.get("app") or ""
            self._last_app = self._app_names.get(cmd, cmd) or None
            return None
        if ev["kind"] == "stream_start":
            ev["app"] = self._last_app
            self._live = {"active": True, "client": ev.get("client"), "app": ev.get("app")}
        elif ev["kind"] == "stream_stop":
            ev["app"] = self._live.get("app")
            self._live = {"active": False, "client": None, "app": None}
        return ev

    def derive_live(self):
        return dict(self._live)

    # ── file tail (not unit-tested; process_line carries the logic) ───────
    def start(self):
        if self._thread or not self._log_path:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._tail, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2.0)
            self._thread = None

    def _tail(self):
        try:
            with open(self._log_path, "r", errors="ignore") as fh:
                fh.seek(0, 2)  # end
                while not self._stop.is_set():
                    line = fh.readline()
                    if not line:
                        time.sleep(self._interval)
                        continue
                    ev = self.process_line(line)
                    if ev is not None:
                        try:
                            self._emit(ev)
                        except Exception:
                            pass
        except OSError:
            return
