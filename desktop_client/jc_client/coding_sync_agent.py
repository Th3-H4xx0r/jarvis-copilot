"""Desktop side of the bidirectional Coding-Session "synced tunnel".

The server (``agent/coding_sync.py``) and this desktop agent are the two peers
of a file-sync tunnel that runs over the device bridge. The server owns the
reconciliation *policy* (manifests, diffs, conflict detection); this client is
the LOCAL FILE ENDPOINT — it snapshots a project folder, serves/receives file
bytes, applies writes/deletes atomically, and watches the folder for local
edits so the server can pull them.

Why the filesystem core is *replicated* here rather than imported
================================================================
The pure-filesystem core lives at ``agent/coding_sync.py`` on the server. The
desktop client is a standalone package (``jc_client``, shipped as a PyInstaller
binary) and does NOT have the ``agent`` package on its import path — so we
cannot ``import agent.coding_sync``. Instead the small, dependency-free pure
functions we need (``is_ignored``, ``build_manifest``, ``safe_join``,
``apply_write``, ``apply_delete``, ``DEFAULT_IGNORES``) are replicated verbatim
below. They are byte-for-byte the same logic as the server so the two peers
agree on manifests and path safety. Keep them in sync if the server's change.

Frames handled (inbound, via ``handle_frame``) and emitted (via ``send``)
========================================================================
Inbound:
  coding_sync_open  {sync_id, path, ignore:[...]}
  coding_sync_get   {sync_id, relpath}
  coding_sync_file  {sync_id, relpath, b64}
  coding_sync_rm    {sync_id, relpath}
  coding_sync_close {sync_id}

Emitted:
  {"type":"coding_sync_manifest","sync_id":id,"manifest":{relpath:[size,mtime,sha]}}
  {"type":"coding_sync_file","sync_id":id,"relpath":r,"b64":<base64>}
  {"type":"coding_sync_event","sync_id":id,"relpath":r,"kind":"create|modify|delete"}
  {"type":"coding_sync_error","sync_id":id,"op":<op>,"error":<msg>}   (best-effort)

A note on the watcher: ``watchdog`` is NOT a client dependency, so we use a
stdlib-only POLLING watcher — a background thread that periodically rebuilds the
manifest and diffs it against the previous snapshot to detect create/modify/
delete. The poll interval is injectable for tests, and the poll body is exposed
as ``_poll_once`` so tests can tick it deterministically.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import tempfile
import threading
import time
from fnmatch import fnmatch
from typing import Callable, Dict, List, Optional, Tuple

log = logging.getLogger(__name__)

# ── cross-process sync indicator ──────────────────────────────────────────────
# On macOS the headless service (`jc-client start --no-tray`) and the menu-bar
# tray (`jc-client tray`) run as SEPARATE processes that share no memory. To let
# the tray show a "Syncing changes…" indicator, the service process (this agent)
# writes a tiny state file that the tray polls. Schema:
#     {"last_transfer_at": <epoch float>, "active": <int active_count()>}
# `last_transfer_at == 0` means "no transfer / idle" (also written on close()).
_SYNC_STATE_FILENAME = "sync_state.json"

# Don't hammer the disk on a burst of file frames — coalesce writes.
_SYNC_STATE_THROTTLE_SEC = 0.4

# How long after the last transfer the tray should keep showing "syncing".
_SYNC_WINDOW_SEC = 2.5

# Sentinel so `state_path=None` (disable file) is distinguishable from "default".
_UNSET = object()


def _sync_state_path() -> Optional[str]:
    """Path to the cross-process sync-state file, or None if unavailable.

    Uses the client's state dir (``~/.jarviscopilot-client/``). Imported lazily
    so this module stays importable in minimal/test contexts where
    ``jc_client.logger`` may pull in heavier deps.
    """
    try:
        from jc_client.logger import state_dir
        return str(state_dir() / _SYNC_STATE_FILENAME)
    except Exception:  # noqa: BLE001 — never let status I/O break sync
        return None

# ── replicated pure-filesystem core (mirror of agent/coding_sync.py) ──────────
# Entry in a manifest: (size_bytes, mtime_seconds, sha256_hex).
ManifestEntry = Tuple[int, float, str]
Manifest = Dict[str, ManifestEntry]

DEFAULT_IGNORES: List[str] = [
    ".git",
    "node_modules",
    "__pycache__",
    ".venv",
    "*.pyc",
    ".DS_Store",
]

_CHUNK_SIZE = 1 << 20  # 1 MiB


def is_ignored(relpath: str, ignores: List[str]) -> bool:
    """Return True if ``relpath`` should be excluded from sync.

    A path matches when *any* of its individual segments matches an ignore
    glob, OR when the full forward-slash relpath matches a glob.
    """
    if not ignores:
        return False
    rel = relpath.replace(os.sep, "/")
    segments = [s for s in rel.split("/") if s]
    for pattern in ignores:
        if fnmatch(rel, pattern):
            return True
        for seg in segments:
            if fnmatch(seg, pattern):
                return True
    return False


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(_CHUNK_SIZE), b""):
            h.update(block)
    return h.hexdigest()


def build_manifest(root: str, ignores: Optional[List[str]] = None) -> Manifest:
    """Walk ``root`` and return ``{relpath: (size, mtime, sha256_hex)}``.

    A missing ``root`` yields an empty manifest (the initial-direction rule
    treats a not-yet-created folder as "empty"). Ignored files/dirs are
    skipped, symlinks are not followed, and unreadable entries are skipped.
    """
    if ignores is None:
        ignores = DEFAULT_IGNORES
    manifest: Manifest = {}
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        return manifest

    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        kept_dirs = []
        for d in dirnames:
            rel_dir = os.path.relpath(os.path.join(dirpath, d), root).replace(
                os.sep, "/"
            )
            if not is_ignored(rel_dir, ignores):
                kept_dirs.append(d)
        dirnames[:] = kept_dirs

        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if is_ignored(rel, ignores):
                continue
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            try:
                st = os.stat(full)
                manifest[rel] = (st.st_size, st.st_mtime, _sha256_file(full))
            except OSError:
                continue
    return manifest


def safe_join(root: str, relpath: str) -> str:
    """Join ``relpath`` onto ``root``, rejecting any escape from ``root``.

    Raises ``ValueError`` for absolute relpaths, ``..`` traversal, NUL bytes,
    or paths that — after resolving existing symlinks via realpath — land
    outside ``root``.
    """
    if "\x00" in relpath:
        raise ValueError("relpath contains NUL byte")
    if os.path.isabs(relpath):
        raise ValueError(f"absolute relpath not allowed: {relpath!r}")

    root_abs = os.path.abspath(root)
    candidate = os.path.normpath(os.path.join(root_abs, relpath))

    if candidate != root_abs and not candidate.startswith(root_abs + os.sep):
        raise ValueError(f"path escapes root: {relpath!r}")

    real_root = os.path.realpath(root_abs)
    probe = candidate
    while not os.path.exists(probe):
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    real_probe = os.path.realpath(probe)
    if real_probe != real_root and not real_probe.startswith(real_root + os.sep):
        raise ValueError(f"path escapes root via symlink: {relpath!r}")

    return candidate


def apply_write(root: str, relpath: str, data: bytes) -> None:
    """Atomically write ``data`` to ``root/relpath`` (path-traversal safe)."""
    target = safe_join(root, relpath)
    parent = os.path.dirname(target)
    os.makedirs(parent, exist_ok=True)

    fd, tmp = tempfile.mkstemp(dir=parent, prefix=".sync-tmp-")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def apply_delete(root: str, relpath: str) -> None:
    """Delete ``root/relpath`` (path-traversal safe). No-op if missing."""
    target = safe_join(root, relpath)
    try:
        os.remove(target)
    except FileNotFoundError:
        pass


# ── the agent ─────────────────────────────────────────────────────────────────

# Default debounce / poll interval for the local watcher.
_DEFAULT_POLL_INTERVAL = 0.5


class _Sync:
    """Per-sync state: the resolved root, ignore rules, and last snapshot."""

    __slots__ = ("sync_id", "root", "ignores", "snapshot")

    def __init__(self, sync_id: str, root: str, ignores: List[str],
                 snapshot: Manifest):
        self.sync_id = sync_id
        self.root = root
        self.ignores = ignores
        self.snapshot = snapshot


class CodingSyncAgent:
    """Desktop endpoint for the bidirectional coding-session file sync.

    Construct with a ``send(frame: dict)`` callable (the connection's frame
    sender). Feed inbound bridge frames to :meth:`handle_frame`; it never
    raises. A background polling watcher (no ``watchdog`` dependency) emits
    ``coding_sync_event`` frames when the local folder changes.

    Public API
    ----------
    ``handle_frame(frame: dict) -> None``  — dispatch one inbound frame.
    ``active_count() -> int``              — number of currently-open syncs.
    ``active_syncs() -> list[str]``        — the open sync_ids (snapshot copy).
    ``close() -> None``                    — stop every watcher, forget all syncs.
    """

    def __init__(self, send: Callable[[dict], None], *,
                 poll_interval: float = _DEFAULT_POLL_INTERVAL,
                 state_path: Optional[str] = _UNSET):
        self._send = send
        self._poll_interval = poll_interval
        self._syncs: Dict[str, _Sync] = {}
        self._lock = threading.RLock()
        # One watcher thread per open sync, plus a stop-event per sync.
        self._threads: Dict[str, threading.Thread] = {}
        self._stops: Dict[str, threading.Event] = {}
        # Cross-process "syncing" indicator state-file bookkeeping. Default
        # resolves to ~/.jarviscopilot-client/sync_state.json; tests pass an
        # explicit path. Pass None to disable the file entirely.
        if state_path is _UNSET:
            state_path = _sync_state_path()
        self._state_path: Optional[str] = state_path
        self._state_lock = threading.Lock()
        self._last_state_write = 0.0     # monotonic-ish epoch of last disk write
        self._last_transfer_at = 0.0     # epoch of most-recent transfer (in mem)

    # ── status (read by the tray) ───────────────────────────────────────

    def active_count(self) -> int:
        """Number of currently-open syncs. Thread-safe; cheap.

        Read by the tray (via the in-process Service) to surface a
        "Sync: N active" status line.
        """
        with self._lock:
            return len(self._syncs)

    def active_syncs(self) -> list:
        """Snapshot list of the currently-open sync_ids. Thread-safe."""
        with self._lock:
            return list(self._syncs.keys())

    def is_syncing(self, now: Optional[float] = None,
                   window: float = _SYNC_WINDOW_SEC) -> bool:
        """True if a file transfer happened within ``window`` seconds.

        Mirrors how the tray decides whether to show the "Syncing changes…"
        indicator (it reads ``last_transfer_at`` from the state file; this
        reads the same value held in memory). ``now`` is injectable for tests.
        """
        if now is None:
            now = time.time()
        return self._last_transfer_at > 0.0 and (now - self._last_transfer_at) < window

    # ── cross-process sync indicator (state file) ───────────────────────

    def _touch_sync_state(self) -> None:
        """Record a transfer and (throttled) flush the state file to disk.

        Called on every sync transfer (get/file/event). Writes are coalesced to
        at most once per ``_SYNC_STATE_THROTTLE_SEC`` so a burst of file frames
        doesn't hammer the disk; the in-memory ``_last_transfer_at`` always
        advances so :meth:`is_syncing` stays accurate between flushes.
        """
        now = time.time()
        self._last_transfer_at = now
        with self._state_lock:
            if (now - self._last_state_write) < _SYNC_STATE_THROTTLE_SEC:
                return
            self._last_state_write = now
            self._write_sync_state(now, self.active_count())

    def _clear_sync_state(self) -> None:
        """Write the idle sentinel (``last_transfer_at == 0``) on close."""
        self._last_transfer_at = 0.0
        with self._state_lock:
            self._last_state_write = time.time()
            self._write_sync_state(0.0, 0)

    def _write_sync_state(self, last_transfer_at: float, active: int) -> None:
        """Atomically (temp+rename) write the state file. Best-effort."""
        path = self._state_path
        if not path:
            return
        payload = {"last_transfer_at": last_transfer_at, "active": int(active)}
        try:
            parent = os.path.dirname(path) or "."
            os.makedirs(parent, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=parent, prefix=".sync-state-")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    json.dump(payload, fh)
                os.replace(tmp, path)
            except BaseException:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
        except Exception as exc:  # noqa: BLE001 — status I/O must never break sync
            log.debug("coding_sync state-file write failed: %s", exc)

    # ── inbound frame dispatch ──────────────────────────────────────────

    def handle_frame(self, frame: dict) -> None:
        """Dispatch one inbound frame. Never raises out of this method."""
        try:
            if not isinstance(frame, dict):
                return
            msg_type = frame.get("type")
            sync_id = frame.get("sync_id") or ""
            if msg_type == "coding_sync_open":
                self._on_open(sync_id, frame)
            elif msg_type == "coding_sync_get":
                self._on_get(sync_id, frame)
            elif msg_type == "coding_sync_file":
                self._on_file(sync_id, frame)
            elif msg_type == "coding_sync_rm":
                self._on_rm(sync_id, frame)
            elif msg_type == "coding_sync_close":
                self._on_close(sync_id)
            # Unknown types: ignore (other handlers own them).
        except Exception as exc:  # noqa: BLE001 — defensive; never bubble up
            log.warning("coding_sync handle_frame failed: %s", exc)
            try:
                self._emit_error(frame.get("sync_id") if isinstance(frame, dict)
                                 else "", frame.get("type") if isinstance(frame, dict)
                                 else "", exc)
            except Exception:
                pass

    # ── handlers ────────────────────────────────────────────────────────

    def _on_open(self, sync_id: str, frame: dict) -> None:
        if not sync_id:
            return
        raw_path = frame.get("path") or ""
        ignore = frame.get("ignore")
        ignores = list(ignore) if isinstance(ignore, list) else list(DEFAULT_IGNORES)
        root = os.path.abspath(os.path.expanduser(str(raw_path)))
        # Per the rule: do NOT create the folder. A missing folder is treated
        # as empty (build_manifest returns {}), which the server reads as
        # "remote is empty" → it will PUSH to seed us.
        manifest = build_manifest(root, ignores)

        with self._lock:
            # Re-opening an existing sync_id: tear down the old watcher first.
            self._stop_watcher_locked(sync_id)
            self._syncs[sync_id] = _Sync(sync_id, root, ignores, dict(manifest))
            self._start_watcher_locked(sync_id)

        self._send_frame({
            "type": "coding_sync_manifest",
            "sync_id": sync_id,
            "manifest": _manifest_to_wire(manifest),
        })

    def _on_get(self, sync_id: str, frame: dict) -> None:
        sync = self._get_sync(sync_id)
        if sync is None:
            return
        relpath = str(frame.get("relpath") or "")
        try:
            target = safe_join(sync.root, relpath)
            with open(target, "rb") as fh:
                data = fh.read()
        except (ValueError, OSError) as exc:
            log.warning("coding_sync_get %s failed: %s", relpath, exc)
            self._emit_error(sync_id, "coding_sync_get", exc, relpath=relpath)
            return
        self._send_frame({
            "type": "coding_sync_file",
            "sync_id": sync_id,
            "relpath": relpath,
            "b64": base64.b64encode(data).decode("ascii"),
        })
        # A get → we just shipped file bytes to the server: that's a transfer.
        self._touch_sync_state()

    def _on_file(self, sync_id: str, frame: dict) -> None:
        sync = self._get_sync(sync_id)
        if sync is None:
            return
        relpath = str(frame.get("relpath") or "")
        b64 = frame.get("b64") or ""
        try:
            data = base64.b64decode(b64, validate=True)
        except Exception as exc:  # noqa: BLE001 — malformed payload
            log.warning("coding_sync_file %s bad base64: %s", relpath, exc)
            self._emit_error(sync_id, "coding_sync_file", exc, relpath=relpath)
            return
        try:
            apply_write(sync.root, relpath, data)
        except (ValueError, OSError) as exc:
            log.warning("coding_sync_file %s write failed: %s", relpath, exc)
            self._emit_error(sync_id, "coding_sync_file", exc, relpath=relpath)
            return
        # Fold this server-driven write into the snapshot so the watcher does
        # NOT echo it back as a local change (avoids an event feedback loop).
        self._record_applied(sync_id, relpath)
        # A server-driven write landed on disk: that's a transfer.
        self._touch_sync_state()

    def _on_rm(self, sync_id: str, frame: dict) -> None:
        sync = self._get_sync(sync_id)
        if sync is None:
            return
        relpath = str(frame.get("relpath") or "")
        try:
            apply_delete(sync.root, relpath)
        except (ValueError, OSError) as exc:
            log.warning("coding_sync_rm %s failed: %s", relpath, exc)
            self._emit_error(sync_id, "coding_sync_rm", exc, relpath=relpath)
            return
        # Drop from the snapshot so the watcher doesn't re-report the delete.
        self._record_removed(sync_id, relpath)

    def _on_close(self, sync_id: str) -> None:
        if not sync_id:
            return
        with self._lock:
            self._stop_watcher_locked(sync_id)
            self._syncs.pop(sync_id, None)

    def close(self) -> None:
        """Stop every watcher thread and forget all syncs."""
        with self._lock:
            sync_ids = list(self._syncs.keys()) + [
                sid for sid in self._stops if sid not in self._syncs
            ]
            for sid in sync_ids:
                self._stop_watcher_locked(sid)
            self._syncs.clear()
        # Clear the cross-process "syncing" indicator so the tray stops showing
        # it once the connection (and its agent) goes away.
        self._clear_sync_state()
        # Join outside the lock so a poll in flight (which grabs the lock) can
        # finish and exit cleanly.
        self._join_dead_threads()

    # ── watcher ─────────────────────────────────────────────────────────

    def _start_watcher_locked(self, sync_id: str) -> None:
        """Spawn the polling watcher thread for ``sync_id``. Caller holds lock."""
        stop = threading.Event()
        self._stops[sync_id] = stop
        t = threading.Thread(
            target=self._watch_loop, args=(sync_id, stop),
            daemon=True, name=f"coding-sync-{sync_id[:8]}",
        )
        self._threads[sync_id] = t
        t.start()

    def _stop_watcher_locked(self, sync_id: str) -> None:
        """Signal the watcher thread to stop. Caller holds the lock."""
        stop = self._stops.pop(sync_id, None)
        if stop is not None:
            stop.set()
        self._threads.pop(sync_id, None)

    def _join_dead_threads(self) -> None:
        # Best-effort join; daemon threads won't block process exit regardless.
        with self._lock:
            threads = list(self._threads.values())
        for t in threads:
            if t.is_alive():
                t.join(timeout=self._poll_interval * 2 + 1.0)

    def _watch_loop(self, sync_id: str, stop: threading.Event) -> None:
        # Debounced poll: wake every ``poll_interval`` seconds and diff.
        while not stop.wait(self._poll_interval):
            if stop.is_set():
                break
            try:
                self._poll_once(sync_id)
            except Exception as exc:  # noqa: BLE001 — keep the watcher alive
                log.debug("coding_sync watcher poll failed for %s: %s",
                          sync_id, exc)

    def _poll_once(self, sync_id: str) -> None:
        """Rebuild the manifest, diff against the last snapshot, emit events.

        Exposed (underscore-public) so tests can tick the watcher
        deterministically without sleeping on the real poll interval.
        """
        with self._lock:
            sync = self._syncs.get(sync_id)
            if sync is None:
                return
            root, ignores, old = sync.root, sync.ignores, sync.snapshot

        new = build_manifest(root, ignores)

        creates: List[str] = []
        modifies: List[str] = []
        deletes: List[str] = []
        for rel, entry in new.items():
            prev = old.get(rel)
            if prev is None:
                creates.append(rel)
            elif prev[2] != entry[2]:  # sha256 differs → content change
                modifies.append(rel)
        for rel in old:
            if rel not in new:
                deletes.append(rel)

        # Commit the new snapshot before emitting so a concurrent server-driven
        # write/delete (which also updates the snapshot) can't be lost.
        with self._lock:
            sync = self._syncs.get(sync_id)
            if sync is not None:
                sync.snapshot = new

        for rel in sorted(creates):
            self._emit_event(sync_id, rel, "create")
        for rel in sorted(modifies):
            self._emit_event(sync_id, rel, "modify")
        for rel in sorted(deletes):
            self._emit_event(sync_id, rel, "delete")

    # ── snapshot bookkeeping (for server-driven writes/deletes) ─────────

    def _record_applied(self, sync_id: str, relpath: str) -> None:
        """Record a server-driven write into the snapshot (no event echo)."""
        with self._lock:
            sync = self._syncs.get(sync_id)
            if sync is None:
                return
            try:
                target = safe_join(sync.root, relpath)
                st = os.stat(target)
                sync.snapshot[relpath] = (
                    st.st_size, st.st_mtime, _sha256_file(target)
                )
            except (ValueError, OSError):
                # If we can't stat it, drop any stale entry; the next poll will
                # reconcile (and may legitimately report it).
                sync.snapshot.pop(relpath, None)

    def _record_removed(self, sync_id: str, relpath: str) -> None:
        """Record a server-driven delete into the snapshot (no event echo)."""
        with self._lock:
            sync = self._syncs.get(sync_id)
            if sync is not None:
                sync.snapshot.pop(relpath, None)

    # ── helpers ─────────────────────────────────────────────────────────

    def _get_sync(self, sync_id: str) -> Optional[_Sync]:
        with self._lock:
            return self._syncs.get(sync_id)

    def _send_frame(self, frame: dict) -> None:
        try:
            self._send(frame)
        except Exception as exc:  # noqa: BLE001 — connection closed/broken
            log.debug("coding_sync send failed: %s", exc)

    def _emit_event(self, sync_id: str, relpath: str, kind: str) -> None:
        self._send_frame({
            "type": "coding_sync_event",
            "sync_id": sync_id,
            "relpath": relpath,
            "kind": kind,
        })
        # A local change is being pushed to the server: that's a transfer.
        self._touch_sync_state()

    def _emit_error(self, sync_id: str, op: str, exc: BaseException,
                    relpath: Optional[str] = None) -> None:
        frame = {
            "type": "coding_sync_error",
            "sync_id": sync_id or "",
            "op": op or "",
            "error": f"{type(exc).__name__}: {exc}",
        }
        if relpath is not None:
            frame["relpath"] = relpath
        self._send_frame(frame)


def _manifest_to_wire(manifest: Manifest) -> Dict[str, list]:
    """Convert ``{relpath: (size, mtime, sha)}`` → JSON-friendly lists.

    Tuples survive ``json.dumps`` as arrays, but going through lists makes the
    wire shape explicit and round-trips cleanly with the server's manifest.
    """
    return {rel: [entry[0], entry[1], entry[2]] for rel, entry in manifest.items()}
