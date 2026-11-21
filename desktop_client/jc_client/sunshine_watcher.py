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

_PATTERNS = [
    (re.compile(r"CLIENT CONNECTED\s*\[([^\]]+)\]", re.I), "device_connect"),
    (re.compile(r"Launching\s*\[([^\]]+)\]", re.I), "stream_start"),
    (re.compile(r"(CLIENT DISCONNECTED|Session (?:ended|terminated))", re.I), "stream_stop"),
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
            if kind == "device_connect":
                ev["client"] = grp
            elif kind == "stream_start":
                ev["app"] = grp
            return ev
    except Exception:
        return None
    return None


class SunshineWatcher:
    def __init__(self, client, known_certs, emit, log_path=None, interval=1.0):
        self._client = client
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
        ev = parse_log_line(line)
        if ev is None:
            return None
        if ev["kind"] == "device_connect":
            ev["unknown"] = ev["client"] not in self._known
        elif ev["kind"] == "stream_start":
            self._live = {"active": True, "client": ev.get("client"), "app": ev.get("app")}
        elif ev["kind"] == "stream_stop":
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
