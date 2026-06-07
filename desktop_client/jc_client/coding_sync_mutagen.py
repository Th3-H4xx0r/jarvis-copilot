"""Desktop agent that runs Mutagen for coding-session file sync.

Replaces the old hand-rolled ``CodingSyncAgent`` (manifest + base64 over the WS).
The server now sends ``coding_sync_start`` / ``coding_sync_stop``; this agent
drives :class:`~jc_client.coding_mutagen.MutagenDriver` (which SSHes to hermes
through the WS<->TCP relay) and pushes ``coding_sync_status`` frames back so the
WebUI panel reflects real Mutagen state. The actual bytes never touch this WS —
they flow over the relay's SSH stream, which is what fixes the old flooding.

Frames handled (inbound): coding_sync_start, coding_sync_stop.
Frames emitted: coding_sync_status, coding_sync_error.
Also: :meth:`pubkey` ensures the sync key + ssh-config alias and returns the
public key for the server to authorize (sent once on connect by the service).
"""
from __future__ import annotations

import logging
import os
import sys
import threading
from typing import Callable, Optional

from jc_client.coding_mutagen import MutagenDriver, MutagenError
from jc_client import ssh_key

log = logging.getLogger(__name__)

_POLL_INTERVAL = 2.0
_REMOTE_HOST = ssh_key.HOST_ALIAS  # "jc-hermes"


def _default_state_dir() -> str:
    try:
        from jc_client.logger import state_dir
        return str(state_dir())
    except Exception:
        return os.path.expanduser("~/.jarviscopilot-client")


def _relay_proxy_command() -> str:
    """The ssh ProxyCommand that pipes the SSH stream through the WS relay.

    Runs THIS client binary's ``tcp-relay`` subcommand (it reuses the stored
    pairing creds to reach the server's /api/devices/tcp-relay). Quoted so a
    spaced install path survives ssh's ProxyCommand parsing.
    """
    exe = sys.executable if getattr(sys, "frozen", False) else sys.argv[0]
    exe = os.path.abspath(exe or "jc-client")
    return f'"{exe}" tcp-relay'


class CodingMutagenAgent:
    def __init__(self, send: Callable[[dict], None], *,
                 state_dir: Optional[str] = None,
                 driver: Optional[MutagenDriver] = None,
                 proxy_command: Optional[str] = None,
                 poll_interval: float = _POLL_INTERVAL):
        self._send = send
        self._state_dir = state_dir or _default_state_dir()
        self._driver = driver or MutagenDriver()
        self._proxy_command = proxy_command  # resolved lazily (frozen path)
        self._poll = poll_interval
        self._lock = threading.RLock()
        self._stops: dict = {}     # sync_id -> threading.Event
        self._threads: dict = {}   # sync_id -> Thread
        self._pubkey: Optional[str] = None

    # ── key + ssh-config bootstrap ──────────────────────────────────────

    def pubkey(self) -> Optional[str]:
        """Ensure the sync keypair + ssh-config host alias exist; return the
        public key (for the server to add to authorized_keys). Cached; never
        raises (returns None on failure)."""
        if self._pubkey:
            return self._pubkey
        try:
            priv, pub = ssh_key.ensure_keypair(self._state_dir)
            ssh_key.write_ssh_config(
                os.path.expanduser("~"), identity=priv,
                proxy_command=self._proxy_command or _relay_proxy_command())
            self._pubkey = pub.strip()
            return self._pubkey
        except Exception as exc:  # noqa: BLE001
            log.warning("sync key/ssh-config bootstrap failed: %s", exc)
            return None

    # ── inbound frames ──────────────────────────────────────────────────

    def handle_frame(self, frame: dict) -> None:
        try:
            t = frame.get("type")
            if t == "coding_sync_start":
                self._on_start(frame)
            elif t == "coding_sync_stop":
                self._on_stop(frame)
        except Exception as exc:  # noqa: BLE001 — never bubble into the pump
            log.warning("coding_sync_mutagen handle_frame failed: %s", exc)

    def _on_start(self, frame: dict) -> None:
        sync_id = str(frame.get("sync_id") or "")
        local = str(frame.get("local_path") or "")
        remote = str(frame.get("remote_path") or "")
        ignore = frame.get("ignore") if isinstance(frame.get("ignore"), list) else None
        if not sync_id or not local or not remote:
            return
        # Make sure the key + ssh alias + daemon are ready.
        self.pubkey()
        try:
            self._driver.ensure_daemon()
            self._driver.start_sync(session_id=sync_id, local_path=local,
                                    remote_host=_REMOTE_HOST, remote_path=remote,
                                    ignore=ignore or None)
        except MutagenError as exc:
            self._emit_error(sync_id, str(exc))
            return
        self._start_poller(sync_id)

    def _on_stop(self, frame: dict) -> None:
        sync_id = str(frame.get("sync_id") or "")
        if not sync_id:
            return
        self._stop_poller(sync_id)
        try:
            self._driver.stop_sync(sync_id)
        except Exception:
            pass

    # ── status poller ───────────────────────────────────────────────────

    def _start_poller(self, sync_id: str) -> None:
        with self._lock:
            self._stop_poller_locked(sync_id)
            stop = threading.Event()
            self._stops[sync_id] = stop
            t = threading.Thread(target=self._poll_loop, args=(sync_id, stop),
                                 daemon=True, name=f"mutagen-{sync_id[:10]}")
            self._threads[sync_id] = t
            t.start()
        # push one status immediately so the panel leaves "opening" fast
        self._poll_once(sync_id)

    def _poll_loop(self, sync_id: str, stop: threading.Event) -> None:
        while not stop.wait(self._poll):
            if stop.is_set():
                break
            self._poll_once(sync_id)

    def _poll_once(self, sync_id: str) -> None:
        try:
            st = self._driver.status(sync_id)
        except MutagenError as exc:
            self._emit_error(sync_id, str(exc))
            return
        self._emit_status(sync_id, st)

    def _stop_poller(self, sync_id: str) -> None:
        with self._lock:
            self._stop_poller_locked(sync_id)

    def _stop_poller_locked(self, sync_id: str) -> None:
        stop = self._stops.pop(sync_id, None)
        if stop is not None:
            stop.set()
        self._threads.pop(sync_id, None)

    # ── emit ────────────────────────────────────────────────────────────

    def _emit_status(self, sync_id: str, st: dict) -> None:
        self._safe_send({
            "type": "coding_sync_status", "sync_id": sync_id,
            "status": st.get("status", "syncing"),
            "conflicts": int(st.get("conflicts") or 0),
            "done": int(st.get("done") or 0),
            "total": int(st.get("total") or 0),
            "error": st.get("error"),
        })

    def _emit_error(self, sync_id: str, msg: str) -> None:
        self._safe_send({"type": "coding_sync_error", "sync_id": sync_id,
                         "op": "mutagen", "error": msg})

    def _safe_send(self, frame: dict) -> None:
        try:
            self._send(frame)
        except Exception as exc:  # noqa: BLE001
            log.debug("coding_sync_mutagen send failed: %s", exc)

    # ── status / lifecycle (read by the service/tray) ───────────────────

    def active_count(self) -> int:
        with self._lock:
            return len(self._threads)

    def close(self) -> None:
        with self._lock:
            for sync_id in list(self._stops.keys()):
                self._stop_poller_locked(sync_id)
