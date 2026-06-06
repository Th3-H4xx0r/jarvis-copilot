"""Pure-filesystem core for the bidirectional Coding-Session "synced tunnel".

This module is the hardest/riskiest piece of the sync feature, so it is kept
deliberately small, dependency-free (Python stdlib only), and network-free.
The WS transport that ships these manifests/diffs/chunks between peers is wired
up separately on top of this core.

Responsibilities here:
  * decide which files participate (``is_ignored``)
  * snapshot a tree (``build_manifest``)
  * compute a three-way reconciliation plan with conflict detection
    (``diff_manifests``)
  * apply changes safely and atomically, refusing path traversal
    (``safe_join`` / ``apply_write`` / ``apply_delete``)
  * name conflict side-copies (``conflict_copy_name``)
  * stream large files (``iter_chunks``)

Conflict policy (assumptions):
  * A *base* manifest represents the state at the last successful sync.
  * A file is a CONFLICT iff its content hash differs from ``base`` on BOTH
    the local and remote sides (i.e. it was edited on both peers since the
    last sync). The caller resolves conflicts (e.g. by writing a
    ``conflict_copy_name`` side-copy) — this core only *flags* them.
  * With ``base=None`` we cannot attribute change, so any path present on both
    sides with differing hashes is treated as a conflict (safe default).
  * Deletions are only honoured when the file existed in ``base`` (so we never
    "delete" a file that one side simply hasn't created yet). A file deleted on
    one side but unchanged on the other propagates the delete to the other
    side; a file deleted on one side but *modified* on the other is a conflict.
"""

from __future__ import annotations

import hashlib
import os
import tempfile
from fnmatch import fnmatch
from typing import Dict, Iterator, List, Optional, Tuple

__all__ = [
    "DEFAULT_IGNORES",
    "is_ignored",
    "build_manifest",
    "diff_manifests",
    "safe_join",
    "apply_write",
    "apply_delete",
    "conflict_copy_name",
    "iter_chunks",
]

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
    glob, OR when the full forward-slash relpath matches a glob. This means a
    file living under an ignored directory (e.g. ``node_modules/x/y.js``) is
    ignored because the ``node_modules`` segment matches.
    """
    if not ignores:
        return False
    rel = relpath.replace(os.sep, "/")
    segments = [s for s in rel.split("/") if s]
    for pattern in ignores:
        # Whole-path match (lets callers write globs like "build/*.log").
        if fnmatch(rel, pattern):
            return True
        # Per-segment match (so dir names and "*.pyc" hit anywhere in tree).
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

    Ignored files/directories (per ``is_ignored``) are skipped; pruning ignored
    directories also avoids descending into them. Relpaths always use forward
    slashes. Symlinks are not followed during the walk and broken/unreadable
    entries are skipped silently.
    """
    if ignores is None:
        ignores = DEFAULT_IGNORES
    manifest: Manifest = {}
    root = os.path.abspath(root)

    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        # Prune ignored directories in-place so os.walk does not descend.
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
            # Skip symlinks and anything that is not a regular file.
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            try:
                st = os.stat(full)
                manifest[rel] = (st.st_size, st.st_mtime, _sha256_file(full))
            except OSError:
                # Unreadable / vanished mid-walk: skip rather than abort.
                continue
    return manifest


def _hash(entry: Optional[ManifestEntry]) -> Optional[str]:
    return entry[2] if entry is not None else None


def diff_manifests(
    local: Manifest, remote: Manifest, base: Optional[Manifest] = None
) -> Dict[str, List[str]]:
    """Three-way reconcile ``local`` vs ``remote`` against an optional ``base``.

    Returns a dict with sorted relpath lists:
        to_send         -- send local -> remote (local newer/new)
        to_receive      -- receive remote -> local (remote newer/new)
        to_delete_remote-- delete on remote (locally deleted since base)
        to_delete_local -- delete on local (remotely deleted since base)
        conflicts       -- changed on BOTH sides since base (caller resolves)

    See module docstring for the full conflict policy.
    """
    to_send: List[str] = []
    to_receive: List[str] = []
    to_delete_remote: List[str] = []
    to_delete_local: List[str] = []
    conflicts: List[str] = []

    base = base or {}
    paths = set(local) | set(remote) | set(base)

    for path in paths:
        lh = _hash(local.get(path))
        rh = _hash(remote.get(path))
        bh = _hash(base.get(path))

        if lh == rh:
            # Sides already agree (both present & equal, or both absent).
            # Nothing to transfer. (If both absent we simply skip.)
            continue

        local_changed = lh != bh
        remote_changed = rh != bh

        if lh is None:
            # Missing locally.
            if path in base and not remote_changed:
                # Existed at last sync, locally deleted, remote untouched
                # -> propagate deletion to remote.
                to_delete_remote.append(path)
            else:
                # Either brand-new on remote, or remote also changed while
                # local deleted -> bring it down (receive). A delete-vs-modify
                # is resolved in favour of keeping the modified copy.
                to_receive.append(path)
            continue

        if rh is None:
            # Missing remotely.
            if path in base and not local_changed:
                # Existed at last sync, remotely deleted, local untouched
                # -> propagate deletion to local.
                to_delete_local.append(path)
            else:
                to_send.append(path)
            continue

        # Present on both sides with differing hashes.
        if base:
            if local_changed and remote_changed:
                conflicts.append(path)
            elif local_changed:
                to_send.append(path)
            elif remote_changed:
                to_receive.append(path)
            # (one of them must have changed since lh != rh)
        else:
            # No base: cannot attribute the change -> conservative conflict.
            conflicts.append(path)

    return {
        "to_send": sorted(to_send),
        "to_receive": sorted(to_receive),
        "to_delete_remote": sorted(to_delete_remote),
        "to_delete_local": sorted(to_delete_local),
        "conflicts": sorted(conflicts),
    }


def safe_join(root: str, relpath: str) -> str:
    """Join ``relpath`` onto ``root``, rejecting any escape from ``root``.

    Raises ``ValueError`` for absolute relpaths, ``..`` traversal, or paths
    that — after resolving existing symlinks via realpath — land outside
    ``root``. The target file itself need not exist yet (we resolve the
    deepest existing ancestor for the symlink check).
    """
    if "\x00" in relpath:
        raise ValueError("relpath contains NUL byte")
    if os.path.isabs(relpath):
        raise ValueError(f"absolute relpath not allowed: {relpath!r}")

    root_abs = os.path.abspath(root)
    candidate = os.path.normpath(os.path.join(root_abs, relpath))

    # Lexical containment check (cheap, catches plain ../ traversal).
    if candidate != root_abs and not candidate.startswith(root_abs + os.sep):
        raise ValueError(f"path escapes root: {relpath!r}")

    # Symlink-escape check: realpath the deepest existing ancestor and confirm
    # it is still inside the realpath'd root. This catches a symlink that
    # points outside root even when the final path component does not exist.
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
    """Atomically write ``data`` to ``root/relpath`` (path-traversal safe).

    Creates parent directories as needed, writes to a temp file in the same
    directory, flushes+fsyncs, then ``os.replace`` over the target so readers
    never observe a partial file.
    """
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
        # Clean up the temp file on any failure so no leftovers remain.
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def apply_delete(root: str, relpath: str) -> None:
    """Delete ``root/relpath`` (path-traversal safe). No-op if it is missing."""
    target = safe_join(root, relpath)
    try:
        os.remove(target)
    except FileNotFoundError:
        pass


def conflict_copy_name(relpath: str, host: str, ts: int) -> str:
    """Name for a conflict side-copy, e.g. ``f.txt`` -> ``f.txt.conflict-<host>-<ts>``."""
    return f"{relpath}.conflict-{host}-{ts}"


def iter_chunks(path: str, chunk_size: int = _CHUNK_SIZE) -> Iterator[bytes]:
    """Yield ``path``'s bytes in ``chunk_size`` pieces for large-file transfer."""
    with open(path, "rb") as fh:
        while True:
            block = fh.read(chunk_size)
            if not block:
                break
            yield block


# ── initial-sync direction ───────────────────────────────────────────────────
# When a session opts into syncing a project with a remote device, the FIRST
# reconcile picks a direction based on whether the REMOTE folder already has
# content (user rule):
#   - remote has files  -> PULL remote -> server (claude uses the remote's files)
#   - remote is empty    -> PUSH server -> remote (seed the remote from the server)

def is_manifest_empty(manifest: dict) -> bool:
    """True when a manifest has no (non-ignored) files."""
    return not manifest


def decide_initial_direction(*, remote_is_empty: bool) -> str:
    """Return 'push' (server -> remote) when the remote is empty, else 'pull'."""
    return "push" if remote_is_empty else "pull"


def plan_initial_sync(server_manifest: dict, remote_manifest: dict) -> dict:
    """Decide the initial direction + the files to transfer.

    Returns ``{"direction": "push"|"pull", "files": [relpaths]}``:
      - push: every file in the server manifest goes to the remote;
      - pull: every file in the remote manifest comes to the server.
    """
    direction = decide_initial_direction(
        remote_is_empty=is_manifest_empty(remote_manifest))
    if direction == "push":
        return {"direction": "push", "files": sorted(server_manifest.keys())}
    return {"direction": "pull", "files": sorted(remote_manifest.keys())}
