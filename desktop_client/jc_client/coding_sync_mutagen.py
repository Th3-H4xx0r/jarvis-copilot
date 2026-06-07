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
import time
from typing import Callable, Optional

from jc_client.coding_mutagen import MutagenDriver, MutagenError
from jc_client import ssh_key

log = logging.getLogger(__name__)

_POLL_INTERVAL = 2.0
_REMOTE_HOST = ssh_key.HOST_ALIAS  # "jc-hermes"
# Cross-process indicator the tray reads ("Sync: N active" + the % line). The old
# CodingSyncAgent wrote this; we keep the same schema so the tray is unchanged.
_SYNC_STATE_FILENAME = "sync_state.json"


def _default_state_dir() -> str:
    try:
        from jc_client.logger import state_dir
        return str(state_dir())
    except Exception:
        return os.path.expanduser("~/.jarviscopilot-client")


def _relay_proxy_command() -> str:
    """The ssh ProxyCommand that pipes the SSH stream through the WS relay.

    Invokes THIS client's ``tcp-relay`` subcommand (it reuses the stored pairing
    creds to reach /api/devices/tcp-relay). Frozen (PyInstaller): the app binary
    IS the entrypoint, so ``<binary> tcp-relay``. Non-frozen (dev / pip / a
    launchd-started module): ``sys.argv[0]`` isn't reliably re-invocable, so use
    the installed ``jc-client`` console script if present, else the interpreter +
    module (``<python> -m jc_client tcp-relay``). Quoted for spaced paths.
    """
    import shutil
    if getattr(sys, "frozen", False):
        exe = os.path.abspath(sys.executable or "jc-client")
        return f'"{exe}" tcp-relay'
    console = shutil.which("jc-client")
    if console:
        return f'"{console}" tcp-relay'
    return f'"{os.path.abspath(sys.executable)}" -m jc_client tcp-relay'


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
        self._last_status: dict = {}  # sync_id -> last status dict (for the tray)
        self._pubkey: Optional[str] = None
        # Clear any stale "Sync: N active" the OLD agent left behind.
        self._write_sync_state()

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

    def _ensure_engine(self) -> bool:
        """Mutagen present? If not, fetch it once (download) and point the driver
        at it. Best-effort; returns False if it still can't be installed."""
        if self._driver.has_engine():
            return True
        try:
            from jc_client.mutagen_install import ensure_mutagen
            path = ensure_mutagen(self._state_dir,
                                  log_fn=lambda m: log.info("%s", m))
            self._driver.set_path(path)
            return True
        except Exception as exc:  # noqa: BLE001
            log.warning("mutagen auto-install failed: %s", exc)
            return False

    # ── inbound frames ──────────────────────────────────────────────────

    def handle_frame(self, frame: dict) -> None:
        try:
            t = frame.get("type")
            if t == "coding_sync_start":
                self._on_start(frame)
            elif t == "coding_sync_stop":
                self._on_stop(frame)
            elif t == "coding_sync_reconcile":
                self._on_reconcile(frame)
        except Exception as exc:  # noqa: BLE001 — never bubble into the pump
            log.warning("coding_sync_mutagen handle_frame failed: %s", exc)

    def _on_start(self, frame: dict) -> None:
        sync_id = str(frame.get("sync_id") or "")
        local = str(frame.get("local_path") or "")
        remote = str(frame.get("remote_path") or "")
        ignore = frame.get("ignore") if isinstance(frame.get("ignore"), list) else None
        if not sync_id or not local or not remote:
            return
        # Make sure the Mutagen engine is installed (self-heal if a `jc-client
        # update` hasn't fetched it yet) + the key/ssh alias/daemon are ready.
        if not self._ensure_engine():
            self._emit_error(
                sync_id, "Mutagen sync engine is not installed — run "
                         "`jc-client install-mutagen` (or `jc-client update`)")
            return
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
        with self._lock:
            self._last_status.pop(sync_id, None)
        try:
            self._driver.stop_sync(sync_id)
        except Exception:
            pass
        self._write_sync_state()

    def _on_reconcile(self, frame: dict) -> None:
        """Terminate any sync (poller + Mutagen session) NOT in the server's
        authoritative ``active`` set. Fixes the tray's stale "Sync: N active":
        orphans from deleted/stopped sessions, and stale Mutagen sessions left
        over from a previous client run (which have no poller of ours)."""
        active = frame.get("active")
        if not isinstance(active, list):
            return
        active_ids = {str(s) for s in active}
        # 1. stop pollers (and their Mutagen syncs) for ids no longer active.
        with self._lock:
            poller_ids = list(self._threads.keys())
        for sync_id in poller_ids:
            if sync_id not in active_ids:
                self._stop_poller(sync_id)
                with self._lock:
                    self._last_status.pop(sync_id, None)
                try:
                    self._driver.stop_sync(sync_id)
                except Exception:
                    pass
        # 2. terminate orphan Mutagen sessions we have no poller for (e.g. left
        #    by a previous run): any jc-sync-* not mapping to an active id.
        try:
            keep = {self._driver.name_for(sid) for sid in active_ids}
            for name in self._driver.list_session_names():
                if name.startswith("jc-sync-") and name not in keep:
                    self._driver.terminate_by_name(name)
        except Exception as exc:  # noqa: BLE001
            log.debug("reconcile orphan-scan failed: %s", exc)
        self._write_sync_state()

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
        self._write_sync_state()  # active count reflects the new poller now

    def _poll_loop(self, sync_id: str, stop: threading.Event) -> None:
        # First poll runs immediately (in THIS thread, not the WS-handler thread)
        # so the panel leaves 'opening' fast without blocking frame processing or
        # racing a concurrent stop.
        if not stop.is_set():
            self._poll_once(sync_id)
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
        with self._lock:
            self._last_status[sync_id] = dict(st)
        self._safe_send({
            "type": "coding_sync_status", "sync_id": sync_id,
            "status": st.get("status", "syncing"),
            "conflicts": int(st.get("conflicts") or 0),
            "done": int(st.get("done") or 0),
            "total": int(st.get("total") or 0),
            "error": st.get("error"),
        })
        self._write_sync_state()

    def _emit_error(self, sync_id: str, msg: str) -> None:
        with self._lock:
            self._last_status[sync_id] = {"status": "error", "error": msg}
        self._safe_send({"type": "coding_sync_error", "sync_id": sync_id,
                         "op": "mutagen", "error": msg})
        self._write_sync_state()

    def _write_sync_state(self) -> None:
        """Write the cross-process tray indicator (active count + aggregate
        progress). active = running pollers (a synced/idle session still counts);
        the % shows only while actively transferring."""
        import json
        import tempfile
        with self._lock:
            active = len(self._threads)
            statuses = list(self._last_status.values())
        done = sum(int(s.get("done") or 0) for s in statuses)
        total = sum(int(s.get("total") or 0) for s in statuses)
        transferring = any(
            s.get("status") in ("syncing", "opening", "connecting") for s in statuses)
        payload = {
            "last_transfer_at": (time.time() if (transferring and active) else 0.0),
            "active": active, "done": done, "total": total,
        }
        path = os.path.join(self._state_dir, _SYNC_STATE_FILENAME)
        try:
            os.makedirs(self._state_dir, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=self._state_dir, prefix=".sync-state-")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(payload, fh)
            os.replace(tmp, path)
        except Exception as exc:  # noqa: BLE001 — status I/O must never break sync
            log.debug("sync_state write failed: %s", exc)

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
            self._last_status.clear()
        self._write_sync_state()  # active -> 0 so the tray clears
