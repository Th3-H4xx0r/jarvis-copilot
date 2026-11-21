"""Game-streaming power subsystem (Sunshine host / PC side).

Server-gated: when the Game Streaming Power switch is on, the server publishes the
``game_stream_power`` topic to this PC with ``{"on": true, "sunshine": {...}, "log_path": ...}``.
We then tail Sunshine's log (jc_client.sunshine_watcher.SunshineWatcher) and push each event
up to the server as a ``game_stream`` bridge event — the same upward channel pc_lighting uses
(service._send_up_ok). ``{"on": false}`` stops the watcher.

Reuses jc_client.sunshine + jc_client.sunshine_watcher (built + tested); this module only
wires power -> watcher -> send_up. Known client certs are seeded from Sunshine's local API so a
connecting device that isn't paired is flagged ``unknown``.

NOTE (verify live): the per-OS default log paths below are Sunshine's documented defaults;
confirm against the running install and override with the integration's ``log_path`` setting
if it writes elsewhere.
"""
from __future__ import annotations

import logging
import sys
import threading
from pathlib import Path
from typing import Any, Callable

from jc_client.sunshine import SunshineClient
from jc_client.sunshine_watcher import SunshineWatcher

log = logging.getLogger(__name__)


def default_log_path() -> str:
    """Sunshine's default log location for this OS (override via the power payload)."""
    if sys.platform == "win32":
        import os
        base = os.environ.get("PROGRAMFILES", r"C:\Program Files")
        return str(Path(base) / "Sunshine" / "config" / "sunshine.log")
    # Linux + macOS: Sunshine keeps its config and log under the XDG config dir.
    return str(Path.home() / ".config" / "sunshine" / "sunshine.log")


class GameStreamPower:
    """Starts/stops a Sunshine-log watcher on the ``game_stream_power`` topic and forwards
    each watcher event up to the server. Idempotent: a second "on" with a watcher already
    running is a no-op; "off" tears it down."""

    def __init__(self, send_up: Callable[[dict], Any], *,
                 client_factory: Callable[..., Any] = SunshineClient,
                 watcher_factory: Callable[..., Any] = SunshineWatcher) -> None:
        self._send_up = send_up
        self._client_factory = client_factory
        self._watcher_factory = watcher_factory
        self._lock = threading.Lock()
        self._watcher = None

    # ── topic handler ────────────────────────────────────────────────────
    def handle_power(self, data: dict | None) -> None:
        data = data or {}
        if data.get("on"):
            self._start(data)
        else:
            self._stop()

    def _start(self, data: dict) -> None:
        with self._lock:
            if self._watcher is not None:
                return
            conn = data.get("sunshine") or {}
            log_path = str(data.get("log_path") or "").strip() or default_log_path()
            known = self._seed_known(conn)
            watcher = self._watcher_factory(None, known, self._emit, log_path=log_path)
            try:
                watcher.start()
            except Exception:  # noqa: BLE001 — a missing log file must not crash the client
                log.warning("game-stream watcher failed to start", exc_info=True)
                return
            self._watcher = watcher
            log.info("game-stream watcher tailing %s (%d known clients)", log_path, len(known))

    def _seed_known(self, conn: dict) -> set:
        """Paired client names from Sunshine's local API, so a new device is flagged unknown.
        Any failure (Sunshine down / bad creds) just yields an empty set — we still watch."""
        if not conn.get("host"):
            return set()
        try:
            client = self._client_factory(
                conn.get("host", "127.0.0.1"), int(conn.get("port", 47990) or 47990),
                conn.get("user", ""), conn.get("password", ""),
                scheme=conn.get("scheme", "https"))
            return {c.get("name") for c in (client.get_clients() or []) if c.get("name")}
        except Exception:  # noqa: BLE001
            log.debug("could not seed known Sunshine clients", exc_info=True)
            return set()

    def _stop(self) -> None:
        with self._lock:
            watcher, self._watcher = self._watcher, None
        if watcher is not None:
            try:
                watcher.stop()
            except Exception:  # noqa: BLE001
                log.debug("game-stream watcher stop failed", exc_info=True)

    def _emit(self, ev: dict) -> None:
        try:
            self._send_up({"type": "event", "name": "game_stream", "data": ev})
        except Exception:  # noqa: BLE001
            log.debug("game-stream event send failed", exc_info=True)

    def stop(self) -> None:
        """Tear down on shutdown."""
        self._stop()
