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

PAIR_POLL_SECONDS = 5.0


def default_log_path() -> str:
    """Sunshine's default log location for this OS (override via the power payload)."""
    if sys.platform == "win32":
        import os
        base = os.environ.get("PROGRAMFILES", r"C:\Program Files")
        return str(Path(base) / "Sunshine" / "config" / "sunshine.log")
    # Linux + macOS: Sunshine keeps its config and log under the XDG config dir.
    return str(Path.home() / ".config" / "sunshine" / "sunshine.log")


def sunshine_apps(log_path: str) -> dict:
    """{command: app name} from Sunshine's apps.json (next to its log), so the watcher can
    name the app Sunshine launched — its log shows only the command. Never raises."""
    import json
    names = {"Desktop": "Desktop"}
    try:
        cfg = Path(log_path).parent / "apps.json"
        data = json.loads(cfg.read_text(encoding="utf-8"))
        for app in data.get("apps") or []:
            name = str(app.get("name") or "").strip()
            if not name:
                continue
            cmd = app.get("cmd")
            if isinstance(cmd, str) and cmd.strip():
                names[cmd.strip()] = name
            for det in app.get("detached") or []:
                if isinstance(det, str) and det.strip():
                    names[det.strip()] = name
    except Exception:  # noqa: BLE001
        pass
    return names


class GameStreamPower:
    """Starts/stops a Sunshine-log watcher on the ``game_stream_power`` topic and forwards
    each watcher event up to the server. Idempotent: a second "on" with a watcher already
    running is a no-op; "off" tears it down."""

    def __init__(self, send_up: Callable[[dict], Any], *,
                 client_factory: Callable[..., Any] = SunshineClient,
                 watcher_factory: Callable[..., Any] = SunshineWatcher,
                 poll_pairs: bool = True) -> None:
        self._send_up = send_up
        self._client_factory = client_factory
        self._watcher_factory = watcher_factory
        self._poll_pairs = poll_pairs
        self._lock = threading.Lock()
        self._watcher = None
        self._seen_pairs: set = set()
        self._poll_stop = threading.Event()
        self._poll_thread = None

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
            watcher = self._watcher_factory(None, known, self._emit, log_path=log_path,
                                            app_names=sunshine_apps(log_path))
            try:
                watcher.start()
            except Exception:  # noqa: BLE001 — a missing log file must not crash the client
                log.warning("game-stream watcher failed to start", exc_info=True)
                return
            self._watcher = watcher
            log.info("game-stream watcher tailing %s (%d known clients)", log_path, len(known))
            if self._poll_pairs and conn:
                self._poll_stop.clear()
                self._poll_thread = threading.Thread(target=self._poll_loop, args=(conn,),
                                                     name="game-stream-pairs", daemon=True)
                self._poll_thread.start()

    # ── pair requests: an unpaired device can't stream; it must ask to pair first ──
    def _poll_loop(self, conn: dict) -> None:
        try:
            client = self._client_factory(
                conn.get("host") or "127.0.0.1", int(conn.get("port", 47990) or 47990),
                conn.get("user", ""), conn.get("password", ""), scheme=conn.get("scheme", "https"))
        except Exception:  # noqa: BLE001
            return
        while not self._poll_stop.wait(PAIR_POLL_SECONDS):
            self._poll_pairs_once(client)

    def _poll_pairs_once(self, client) -> None:
        """Send up each new pending pair request once ({kind: pair_request, ...}); a request
        that clears and comes back is new again. Never raises."""
        try:
            pending = client.pending_pairings() or []
        except Exception:  # noqa: BLE001
            return
        ids = set()
        for p in pending:
            pid = str((p or {}).get("id") or "")
            if not pid:
                continue
            ids.add(pid)
            if pid in self._seen_pairs:
                continue
            self._seen_pairs.add(pid)
            self._emit({"kind": "pair_request", "client": str(p.get("name") or "A device"),
                        "address": str(p.get("address") or ""), "id": pid})
        self._seen_pairs &= ids

    def _seed_known(self, conn: dict) -> set:
        """Paired client names from Sunshine's local API, so a new device is flagged unknown.
        Any failure (Sunshine down / bad creds) just yields an empty set — we still watch."""
        if not conn:
            return set()
        try:
            # Sunshine runs on this PC: the server sends only the login, so default to localhost.
            client = self._client_factory(
                conn.get("host") or "127.0.0.1", int(conn.get("port", 47990) or 47990),
                conn.get("user", ""), conn.get("password", ""),
                scheme=conn.get("scheme", "https"))
            return {c.get("name") for c in (client.get_clients() or []) if c.get("name")}
        except Exception:  # noqa: BLE001
            log.debug("could not seed known Sunshine clients", exc_info=True)
            return set()

    def _stop(self) -> None:
        self._poll_stop.set()
        with self._lock:
            watcher, self._watcher = self._watcher, None
            self._poll_thread = None
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
