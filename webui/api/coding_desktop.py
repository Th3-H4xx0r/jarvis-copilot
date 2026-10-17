"""Server side of the Mac's coding file sync and folder listing, over the device bridge.

The device-bridge connection registry lives in *this* (webui) process, so the
send path is in-process (``device_bridge.send_frame``). This module:

  1. drives each synced project's Mutagen file sync (the Mac runs Mutagen over
     the WS<->TCP relay; the server tells it what to sync and keeps the status
     it reports), and
  2. asks a Mac to list a folder for the folder typeahead (``/dir-suggest``).

Frames
------
  Sync       S->D  coding_sync_start {sync_id, local_path, remote_path, ignore}
                   coding_sync_stop  {sync_id}
                   coding_sync_reconcile {active}
             D->S  coding_sync_status{sync_id, status, conflicts, done, total, error}
                   coding_sync_error {sync_id, op, error}
                   coding_sync_authorize_key {pubkey}
        (the file bytes flow over the separate WS<->TCP relay + SSH + Mutagen on
         the desktop — they never touch this control bridge)

  Folders    S->D  coding_dir_list_get  {req_id, path}
             D->S  coding_dir_list_data {req_id, ok, dirs | error}

Every class takes an injectable *transport* — anything with
``send(device_id, frame) -> bool`` — so tests pass a fake that records frames
and inject inbound ones through ``DesktopBridge.on_frame``.
"""
from __future__ import annotations

import hashlib
import logging
import os
import threading
import time
import uuid

log = logging.getLogger(__name__)

# Where a Mac project's synced copy lives ON THE SERVER. Overridable via env so
# deployments can relocate it; defaults to ~/codingprojects. Referenced through
# ``_server_projects_root()`` so tests can monkeypatch it.
SERVER_PROJECTS_ROOT = os.path.expanduser("~/codingprojects")


def _server_projects_root() -> str:
    """Server-side root dir of the synced project copies
    (``<root>/<basename(mac folder)>``). Env ``JC_CODING_PROJECTS_ROOT`` wins;
    otherwise the module-level ``SERVER_PROJECTS_ROOT`` (monkeypatchable)."""
    return os.environ.get("JC_CODING_PROJECTS_ROOT") or SERVER_PROJECTS_ROOT


# Disk-guard kill-switch: the housekeeping disk guard sets this when the server disk
# is critically full so NO new sync can start (existing ones are paused separately).
# Process-local; cleared when the disk recovers. Read by ``start_sync_for_launch``.
# The disk guard re-stamps ``at`` every tick (~30s) while blocked; ``sync_blocked``
# self-expires a block older than the TTL so a dead/hung guard thread can't block
# syncs FOREVER (fail-open after the guard stops asserting).
_SYNC_BLOCK = {"blocked": False, "reason": "", "at": 0.0}
_SYNC_BLOCK_TTL = 180.0  # seconds; ~6 guard ticks


def sync_blocked() -> bool:
    if not _SYNC_BLOCK["blocked"]:
        return False
    if (time.monotonic() - float(_SYNC_BLOCK.get("at", 0.0))) > _SYNC_BLOCK_TTL:
        return False  # stale → the guard stopped re-asserting; fail open
    return True


def set_sync_blocked(blocked: bool, reason: str = "") -> None:
    _SYNC_BLOCK["blocked"] = bool(blocked)
    _SYNC_BLOCK["reason"] = reason or ""
    _SYNC_BLOCK["at"] = time.monotonic()

# ── transport seam ───────────────────────────────────────────────────────────


class _RealTransport:
    """Default transport: the in-process device-bridge send path."""

    def send(self, device_id: str, frame: dict) -> bool:
        from api import device_bridge

        return device_bridge.send_frame(device_id, frame)


# ── the bridge helper ────────────────────────────────────────────────────────


class DesktopBridge:
    """Server-side helper that sends coding frames to a device and routes the
    device's replies back to the right sync session / folder-list request.

    Single instance per webui process (``get_desktop_bridge()``). It owns the
    process-wide inbound coding-frame handler registered with the device bridge.
    """

    def __init__(self, transport=None):
        self._transport = transport or _RealTransport()
        self._lock = threading.RLock()
        # sync_id -> MutagenSyncSession
        self._syncs: dict = {}
        # req_id -> {"event":Event, "dirs":list|None, "error":str|None} —
        # in-flight device directory-listing requests (request_dir_list).
        self._dir_waiters: dict[str, dict] = {}

    # --- registration with the device bridge --------------------------------

    def install(self) -> None:
        """Register this instance as the device bridge's coding-frame handler."""
        from api import device_bridge

        device_bridge.set_coding_frame_handler(self.on_frame)

    # --- outbound sync frames -----------------------------------------------

    def send_sync_start(self, device_id: str, *, sync_id: str, local_path: str,
                        remote_path: str, ignore: list | None = None) -> bool:
        """Tell the desktop to start a Mutagen sync for this session: its LOCAL
        folder (``local_path``) <-> the server's session cwd (``remote_path``,
        reached over the WS<->TCP relay's ssh alias)."""
        return self._transport.send(device_id, {
            "type": "coding_sync_start", "sync_id": sync_id,
            "local_path": local_path, "remote_path": remote_path,
            "ignore": list(ignore or []),
        })

    def send_sync_stop(self, device_id: str, sync_id: str) -> bool:
        with self._lock:
            self._syncs.pop(sync_id, None)
        return self._transport.send(device_id, {
            "type": "coding_sync_stop", "sync_id": sync_id,
        })

    def send_sync_reconcile(self, device_id: str, active_sync_ids: list) -> bool:
        """Tell the desktop the AUTHORITATIVE set of syncs that should be running
        right now (one per live coding session). The desktop terminates any
        Mutagen sync + status poller NOT in this set — cleaning up orphans left
        by deleted/stopped sessions (including deletes that happened while the
        client was offline, or stale Mutagen sessions after a client restart).
        This is what keeps the tray's "Sync: N active" count honest."""
        active = [str(s) for s in (active_sync_ids or [])]
        with self._lock:
            for sid in list(self._syncs.keys()):
                if sid not in active:
                    self._syncs.pop(sid, None)
        return self._transport.send(device_id, {
            "type": "coding_sync_reconcile", "active": active,
        })

    # --- directory listing request/response (working-dir autocomplete) ------

    def request_dir_list(self, device_id: str, *, path: str,
                         timeout: float = 8.0) -> list[str] | None:
        """Ask a connected device to list immediate sub-directories of ``path``
        (typeahead for the coding form's Working Directory / sync-folder fields
        when the host is a paired device). Sends ``coding_dir_list_get`` and
        blocks up to ``timeout`` for a ``coding_dir_list_data`` reply.

        Returns the list of absolute dir paths, or ``None`` on offline / timeout
        / device error. Always cleans up the waiter; never blocks past
        ``timeout``; never raises."""
        req_id = uuid.uuid4().hex
        waiter = {"event": threading.Event(), "dirs": None, "error": None}
        with self._lock:
            self._dir_waiters[req_id] = waiter
        try:
            ok = self._transport.send(device_id, {
                "type": "coding_dir_list_get", "req_id": req_id,
                "path": path or "",
            })
            if not ok:
                return None  # device not connected
            if not waiter["event"].wait(timeout):
                return None
            with self._lock:
                err = waiter["error"]
                dirs = waiter["dirs"]
            if err:
                return None
            return list(dirs or [])
        finally:
            with self._lock:
                self._dir_waiters.pop(req_id, None)

    def register_sync(self, session) -> None:
        with self._lock:
            self._syncs[session.sync_id] = session

    def sync_for(self, sync_id: str):
        with self._lock:
            return self._syncs.get(sync_id)

    # --- inbound frame routing (called from the bridge pump thread) ---------

    def on_frame(self, device_id: str, frame: dict) -> None:
        t = frame.get("type")
        if t == "coding_sync_authorize_key":
            self._authorize_sync_key(frame.get("pubkey") or "")
        elif t in ("coding_sync_status", "coding_sync_error"):
            self._route_sync(frame)
        elif t == "coding_dir_list_data":
            self._route_dir_list(frame)

    def _route_dir_list(self, frame: dict) -> None:
        """Resolve an in-flight request_dir_list with the device's reply (a list
        of dir paths, or an error). Runs on the bridge pump thread."""
        req_id = frame.get("req_id")
        if not req_id:
            return
        with self._lock:
            waiter = self._dir_waiters.get(req_id)
            if waiter is None:
                return  # unknown or already timed-out request
            if frame.get("ok") is False or frame.get("error"):
                waiter["error"] = str(frame.get("error") or "dir list failed")
            else:
                dirs = frame.get("dirs")
                waiter["dirs"] = [str(d) for d in dirs] if isinstance(
                    dirs, list) else []
            waiter["event"].set()

    def _authorize_sync_key(self, pubkey: str) -> None:
        """Add the desktop's sync SSH public key to the server's authorized_keys
        so Mutagen (over the WS<->TCP relay) can connect. Idempotent + defensive
        — a bad key or fs error must never break the bridge."""
        try:
            from agent.sync_authorized_keys import add_authorized_key
            res = add_authorized_key(pubkey)
            if res.get("error"):
                log.warning("coding_sync_authorize_key rejected: %s", res["error"])
            elif res.get("added"):
                log.info("coding_sync: authorized desktop sync key -> %s",
                         res.get("path"))
        except Exception as exc:  # noqa: BLE001
            log.warning("coding_sync_authorize_key failed: %s", exc)

    def _route_sync(self, frame: dict) -> None:
        sync = self.sync_for(frame.get("sync_id"))
        if sync is None:
            return
        t = frame.get("type")
        if t == "coding_sync_status":
            sync.on_status(frame)
        elif t == "coding_sync_error":
            sync.on_error(frame.get("op") or "", frame.get("error") or "",
                          frame.get("relpath"))


# ── sync session (server side of the synced tunnel) ──────────────────────────


class MutagenSyncSession:
    """Server-side state for ONE folder pair's Mutagen sync (a synced project).

    The actual file sync runs on the DESKTOP (Mutagen over the WS<->TCP relay).
    This object only (a) tells the desktop to start/stop the sync and (b) holds
    the latest status the desktop pushes back, for the WebUI sync panel. It owns
    no transfer logic — that is Mutagen's job now.

    ``local_path``  = the desktop's working folder to sync.
    ``remote_path`` = its copy on the server (where a continued session runs).
    """

    # Re-send coding_sync_start if the desktop never reports status (handshake
    # lost to a reconnect); generous so a slow initial scan isn't restarted.
    _REOPEN_STALE_SECS = 45.0

    def __init__(self, *, sync_id, device_id, local_path, remote_path, bridge,
                 ignore=None):
        self.sync_id = str(sync_id)
        self.device_id = str(device_id)
        self.local_path = str(local_path or "")
        self.remote_path = str(remote_path or "")
        self.bridge = bridge
        self.ignore = list(ignore) if ignore else None
        # status surfaced to the WebUI:
        #   opening | syncing | synced | conflicts | error
        self.status = "opening"
        self.direction = None  # parity field (Mutagen is bidirectional)
        self.conflicts = 0
        self.healed = 0
        self.done = 0
        self.total = 0
        self.last_sync_at = None
        self.error = None
        self._last_open_at = 0.0

    def open(self) -> bool:
        """Tell the desktop to (re)start the Mutagen sync for this session."""
        self.status = "opening"
        self._last_open_at = time.time()
        ok = self.bridge.send_sync_start(
            self.device_id, sync_id=self.sync_id, local_path=self.local_path,
            remote_path=self.remote_path, ignore=self.ignore)
        log.info("coding_sync[%s] start -> device=%s local=%s remote=%s sent=%s",
                 self.sync_id, self.device_id, self.local_path,
                 self.remote_path, ok)
        return ok

    def reopen_if_stale(self, now=None) -> bool:
        """Re-send coding_sync_start if we've been stuck waiting to connect for
        too long (the start frame was lost to a reconnect, or Mutagen's ssh
        through the relay never came up). Fires while 'opening' OR 'connecting'."""
        if self.status not in ("opening", "connecting"):
            return False
        if now is None:
            now = time.time()
        if self._last_open_at and (now - self._last_open_at) < self._REOPEN_STALE_SECS:
            return False
        log.info("coding_sync[%s] re-start: no status after %.0fs",
                 self.sync_id, now - (self._last_open_at or now))
        self.open()
        return True

    def on_status(self, frame: dict) -> None:
        """The desktop pushed a coding_sync_status frame parsed from Mutagen."""
        status = str(frame.get("status") or "").strip() or self.status
        self.status = status
        self.conflicts = int(frame.get("conflicts") or 0)
        self.healed = int(frame.get("healed") or 0)
        self.done = int(frame.get("done") or 0)
        self.total = int(frame.get("total") or 0)
        self.error = frame.get("error")
        if status == "synced":
            self.last_sync_at = time.time()

    def on_error(self, op: str, error: str, relpath=None) -> None:
        first = self.status != "error" or not str(self.error or "").startswith(op)
        self.error = f"{op}: {error}" + (f" ({relpath})" if relpath else "")
        self.status = "error"
        log.warning("coding_sync[%s] desktop error op=%s: %s",
                    self.sync_id, op, error)
        if op == "git_conflict" and first:
            # The Mac paused this sync: conflicts inside .git need a human.
            try:
                from api.push import alert_phones
                name = os.path.basename(self.local_path.rstrip("/")) or "a project"
                alert_phones(f"Sync paused: {name}", str(error),
                             data={"kind": "sync_git_conflict", "sync_id": self.sync_id})
            except Exception:  # noqa: BLE001
                log.warning("git-conflict alert failed", exc_info=True)

    def close(self) -> None:
        try:
            self.bridge.send_sync_stop(self.device_id, self.sync_id)
        except Exception:
            pass


# ── process-wide singleton ───────────────────────────────────────────────────

_BRIDGE = None
_BRIDGE_LOCK = threading.Lock()


def get_desktop_bridge() -> DesktopBridge:
    """The webui process's DesktopBridge (installs the device-bridge handler on
    first use)."""
    global _BRIDGE
    with _BRIDGE_LOCK:
        if _BRIDGE is None:
            _BRIDGE = DesktopBridge()
            try:
                _BRIDGE.install()
            except Exception:
                # device_bridge import may fail in some contexts; the bridge is
                # still usable for outbound sends if a transport is wired later.
                pass
        return _BRIDGE


# Pairing ``kind``s that can NEVER run Mutagen file sync. Only MOBILE apps are
# excluded: they hold a live device-bridge WebSocket too (notifications /
# phone-control), so "connected to the bridge" alone isn't proof of a desktop
# agent. NOTE: a desktop jc-client registers with kind=='desktop' OR — very
# commonly — the DEFAULT kind=='browser' (only the mobile app flips its kind
# after pairing), so 'browser'/'' must NOT be excluded here. Actual web
# browsers never hold a device-bridge WS, so they're filtered out by the
# bridge_connected requirement, not by kind.
NON_SYNC_KINDS = frozenset({"mobile-ios", "mobile"})


def is_sync_capable_kind(kind: str | None) -> bool:
    """True unless ``kind`` is a known mobile pairing (which can't run Mutagen
    even though it holds a device-bridge WS)."""
    return (kind or "").strip().lower() not in NON_SYNC_KINDS


def _connected_sync_capable() -> list:
    """Connected device ids that can actually run Mutagen sync (desktop
    jc-clients), in a stable order. Excludes mobile/browser pairings even though
    they hold a bridge WS."""
    try:
        from api import device_bridge

        connected = list(device_bridge.connected_device_ids())
    except Exception:
        return []
    if not connected:
        return []
    try:
        from api.pairing import list_devices

        kind_of = {d.get("id"): (d.get("kind") or "") for d in list_devices()}
    except Exception:
        kind_of = {}
    return [cid for cid in connected if is_sync_capable_kind(kind_of.get(cid))]


def resolve_desktop_device_id(preferred: str | None = None) -> str | None:
    """device_id of a connected jc-client DESKTOP (sync-capable) device, else None.

    A device qualifies only if it holds a live device-bridge WS AND is not a
    mobile/browser pairing (those hold a bridge too but can't run Mutagen). The
    explicitly-chosen ``preferred`` device (by id or name) wins when it's both
    connected and sync-capable.
    """
    capable = _connected_sync_capable()
    if not capable:
        return None
    capable_set = set(capable)
    # 1. honour the explicitly-chosen device (by id or name) if it's connected
    #    AND sync-capable (never resolve a chosen mobile device to itself).
    if preferred:
        if preferred in capable_set:
            return preferred
        try:
            from api.pairing import list_devices

            for d in list_devices():
                if d.get("id") in capable_set and (
                        d.get("id") == preferred
                        or (d.get("name") or "") == preferred
                        or (d.get("device_name") or "") == preferred):
                    return d["id"]
        except Exception:
            pass
    # 2. prefer a relay-capable connected device (still must be sync-capable)
    try:
        from api import device_bridge

        caps = device_bridge.relay_capable_devices()
        if caps and caps[0].get("device_id") in capable_set:
            return caps[0]["device_id"]
    except Exception:
        pass
    # 3. fall back to the first connected sync-capable (desktop) jc-client
    return capable[0]


def repo_sync_id(device_id: str, local_path: str, remote_path: str) -> str:
    """Deterministic sync id for a repo file-sync, keyed by the FOLDER-PAIR
    (device + local folder + remote folder) rather than the session.

    A repo's working dir is per-PROJECT, not per-session — so every coding
    session that syncs the same ``(device, local, remote)`` triple shares ONE
    Mutagen sync instead of each spinning up its own (which is what left N
    overlapping ``jc-sync-cs-*`` syncs fighting over the same two directories)."""
    key = "\x00".join((str(device_id or ""), str(local_path or ""),
                       str(remote_path or "")))
    return "sync-" + hashlib.sha1(key.encode("utf-8")).hexdigest()[:16]


def _row_repo_sync_id(row: dict, sync_config=None) -> str | None:
    """The repo_sync_id for a session ROW (device + the desktop folder from its
    sync_config + the server cwd), or None if the row has no usable sync."""
    import json as _json
    cfg = {}
    raw = sync_config if sync_config is not None else (row.get("sync_config") or "")
    if isinstance(raw, dict):
        cfg = raw
    elif raw:
        try:
            cfg = _json.loads(raw) or {}
        except Exception:
            cfg = {}
    if not (cfg.get("enabled") or cfg.get("device") or cfg.get("remote_path")):
        return None
    device_id = (row.get("device_id") or "").strip() or (cfg.get("device") or "").strip()
    cwd = row.get("cwd") or ""
    local_path = cfg.get("remote_path") or cwd
    if not (device_id and cwd):
        return None
    return repo_sync_id(device_id, local_path, cwd)


def start_sync_for_launch(device_id: str, *, session_id: str, cwd: str,
                          sync: dict | None,
                          bridge: DesktopBridge | None = None):
    """Open a MutagenSyncSession for a session that opted into syncing.

    The desktop runs Mutagen between its LOCAL folder (``sync['remote_path']`` —
    the path on the user's machine) and the server session's cwd
    (``remote_path`` on the Mutagen ``jc-hermes`` ssh alias). Returns the session
    (or None when sync is off).

    The sync is keyed by the FOLDER-PAIR (``repo_sync_id``), so sibling sessions
    on the same project reuse the one sync instead of opening duplicates.
    """
    if not sync:
        return None
    if not (sync.get("enabled") or sync.get("device") or sync.get("remote_path")):
        return None
    bridge = bridge or get_desktop_bridge()
    ignore = sync.get("ignore") if isinstance(sync.get("ignore"), list) else None
    local_path = sync.get("remote_path") or cwd  # the DESKTOP's folder
    # ── SAFEGUARDS: never start a runaway/misconfigured/disk-unsafe sync. ──
    # Validate the endpoints (reject $HOME / system dirs / a Mac path used as the
    # server dest / a server path outside the allowed roots). The Mac-side
    # allowed-root + tree-size checks run on the CLIENT (it can stat the tree).
    try:
        from agent.coding_sync_safety import (
            SyncSafetyConfig, validate_endpoints_for_server_gate)
        ok, why = validate_endpoints_for_server_gate(
            local_path, cwd, SyncSafetyConfig.from_env())
    except Exception:  # never let the guard import/logic crash a launch
        ok, why = True, ""
    if not ok:
        log.warning("coding sync REFUSED (%s): local=%r server=%r",
                    why, local_path, cwd)
        return None
    if sync_blocked():
        log.warning("coding sync blocked by disk guard: %s", _SYNC_BLOCK.get("reason"))
        return None
    try:
        import shutil as _shutil
        from agent.coding_disk_guard import DiskGuardConfig
        floor = DiskGuardConfig.from_env().min_free_bytes
        target = cwd if os.path.isdir(cwd) else _server_projects_root()
        if _shutil.disk_usage(target).free < floor:
            log.warning("coding sync refused: server free space below floor (%d)", floor)
            return None
    except Exception:  # disk path missing (e.g. unit tests) → don't block
        pass
    sync_id = repo_sync_id(device_id, local_path, cwd)
    # If a healthy sync for this exact folder-pair already exists (a sibling
    # session opened it), reuse it — don't open a duplicate Mutagen session.
    existing = bridge.sync_for(sync_id)
    if existing is not None and existing.status not in ("error", "disconnected"):
        return existing
    session = MutagenSyncSession(
        sync_id=sync_id, device_id=device_id, local_path=local_path,
        remote_path=cwd, bridge=bridge, ignore=ignore)
    # NOTE: the conversation transcript (<csid>.jsonl, under ~/.claude/projects)
    # is not part of this sync: the Agents layer copies it line by line
    # (agent/transcript_mirror.py).
    bridge.register_sync(session)
    session.open()  # coding_sync_start -> desktop runs Mutagen, pushes status
    return session


def stop_folder_sync(device_id: str, local_path: str, remote_path: str, *,
                     bridge: DesktopBridge | None = None) -> None:
    """Stop the Mutagen sync of one folder pair (a project whose sync was switched
    off or moved to another folder). Tells the device even when this process has
    no session object for it (e.g. after a webui restart). Never raises."""
    if not (device_id and local_path and remote_path):
        return
    try:
        bridge = bridge or get_desktop_bridge()
        sync_id = repo_sync_id(device_id, local_path, remote_path)
        sess = bridge.sync_for(sync_id)
        if sess is not None:
            sess.close()  # sends coding_sync_stop + deregisters
        else:
            bridge.send_sync_stop(device_id, sync_id)
    except Exception:  # noqa: BLE001
        log.debug("stopping sync of %s failed", local_path, exc_info=True)


def sync_status(session_id: str, sync_config=None, cwd: str | None = None) -> dict:
    """Sync status for the WebUI: device, online/offline, status, progress.

    ``status`` is one of: off | disconnected | idle | opening | syncing | synced
    | error. ``total``/``done`` drive the progress bar while ``syncing``.

    ``cwd`` (the session's server cwd) lets us resolve the shared FOLDER-PAIR
    sync (``repo_sync_id``); without it we fall back to the legacy per-session id.
    """
    import json as _json

    out = {"enabled": False, "device": None, "device_online": False,
           "status": "off", "direction": None, "total": 0, "done": 0,
           "conflicts": 0, "healed": 0, "last_sync_at": None, "error": None}
    cfg = {}
    if sync_config:
        try:
            cfg = (_json.loads(sync_config) if isinstance(sync_config, str)
                   else dict(sync_config))
        except Exception:
            cfg = {}
    if not cfg.get("enabled"):
        return out
    out["enabled"] = True
    out["device"] = cfg.get("device")
    out["device_online"] = bool(resolve_desktop_device_id(preferred=cfg.get("device")))
    sid = None
    if cwd:
        sid = _row_repo_sync_id({"cwd": cwd, "device_id": ""}, sync_config=cfg)
    try:
        bridge = get_desktop_bridge()
        sess = bridge.sync_for(sid) if sid else None
        if sess is None:  # legacy fallback (pre folder-pair keying)
            sess = bridge.sync_for("sync-" + session_id)
    except Exception:
        sess = None
    # Surface last-known progress/direction from any session object we have, but
    # the STATUS must reflect device liveness first: if the desktop client is
    # gone, a left-over session still holding status="syncing" is stale — report
    # "disconnected" (not a frozen "Syncing…") so the panel says offline and the
    # next reconnect/Refresh re-reconciles.
    if sess is not None:
        # Self-heal a sync stuck waiting for the manifest (lost handshake): the
        # WebUI polls this every few seconds, so this re-opens within ~45s.
        if out["device_online"]:
            try:
                sess.reopen_if_stale()
            except Exception:
                pass
        out["direction"] = getattr(sess, "direction", None)
        out["total"] = int(getattr(sess, "total", 0) or 0)
        out["done"] = int(getattr(sess, "done", 0) or 0)
        out["conflicts"] = int(getattr(sess, "conflicts", 0) or 0)
        out["healed"] = int(getattr(sess, "healed", 0) or 0)
        out["last_sync_at"] = getattr(sess, "last_sync_at", None)
        out["error"] = getattr(sess, "error", None)
    if not out["device_online"]:
        out["status"] = "disconnected"
    elif sess is not None:
        out["status"] = getattr(sess, "status", "syncing") or "syncing"
    else:
        # configured, device online, but no live sync session yet
        out["status"] = "idle"
    return out
