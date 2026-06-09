"""Pure safety checks for coding-session file syncs.

A sync mirrors a Mac folder (alpha) <-> a server folder (beta). Without guards it
will happily mirror an entire home directory or a huge tree, or point a Mac path
at the Linux server — which is exactly how the server disk got filled. These are
PURE predicates (no I/O) so they're trivially unit-tested; the one bounded walk
(``estimate_tree``) is invoked by the client only when it has a real local path.

Each endpoint is validated where its ``~`` resolves: the SERVER validates the beta
path (server ``~``), the CLIENT validates the alpha path (Mac ``~``) + tree size.
``is_dangerous_path`` is host-agnostic (pattern-based) so either side catches a
home/system dir even when ``~`` would expand to the wrong machine.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass

# Sync is only allowed UNDER one of these roots (per side). Configurable via env
# so a different layout doesn't require a code change.
_DEFAULT_LOCAL_ROOTS = [
    "~/PranavFiles/coding-projects", "~/codingprojects",
    "~/code", "~/projects", "~/src", "~/dev",
]
_DEFAULT_SERVER_ROOTS = ["~/codingprojects"]

# Single-segment system roots that must never be a sync endpoint.
_SYSTEM_ROOTS = (
    "/etc", "/var", "/usr", "/bin", "/sbin", "/lib", "/lib64", "/boot",
    "/dev", "/proc", "/sys", "/opt", "/srv", "/run", "/mnt", "/media",
)

_GiB = 1024 ** 3
_MiB = 1024 ** 2


@dataclass
class SyncSafetyConfig:
    allowed_local_roots: list
    allowed_server_roots: list
    max_tree_bytes: int = 2 * _GiB
    max_file_bytes: int = 100 * _MiB
    max_files: int = 50_000

    @classmethod
    def from_env(cls, env=None) -> "SyncSafetyConfig":
        env = env if env is not None else os.environ

        def _roots(key, default):
            raw = (env.get(key) or "").strip()
            if raw:
                parts = [p.strip() for p in re.split(r"[:,]", raw) if p.strip()]
                if parts:
                    return parts
            return list(default)

        def _int(key, default):
            try:
                return int(env.get(key) or default)
            except (TypeError, ValueError):
                return default

        return cls(
            allowed_local_roots=_roots("JC_SYNC_ALLOWED_LOCAL_ROOTS", _DEFAULT_LOCAL_ROOTS),
            allowed_server_roots=_roots("JC_SYNC_ALLOWED_SERVER_ROOTS", _DEFAULT_SERVER_ROOTS),
            max_tree_bytes=_int("JC_SYNC_MAX_TREE_BYTES", 2 * _GiB),
            max_file_bytes=_int("JC_SYNC_MAX_FILE_BYTES", 100 * _MiB),
            max_files=_int("JC_SYNC_MAX_FILES", 50_000),
        )


def _norm(path) -> str:
    s = str(path or "").strip()
    if not s:
        return ""
    p = os.path.normpath(os.path.expanduser(s))
    # normpath("") / normpath(".") collapse to "." — treat as empty (dangerous).
    return p if (p and p != ".") else ""


def _segments(path) -> list:
    return [c for c in _norm(path).split(os.sep) if c]


def is_home_like(path) -> bool:
    """A user/system HOME directory: ``$HOME``, ``/Users/<name>``, ``/home/<name>``
    (exactly two segments), or ``/root``. Host-agnostic — pattern based, so the
    server catches a Mac ``/Users/<name>`` and the Mac catches its own ``$HOME``."""
    p = _norm(path)
    if not p:
        return False
    if p == _norm("~"):
        return True
    segs = _segments(p)
    if len(segs) == 2 and segs[0] in ("Users", "home"):
        return True
    if len(segs) == 1 and segs[0] == "root":
        return True
    return False


def is_dangerous_path(path) -> bool:
    """Never sync this: empty, ``/``, a home dir, or a top-level system dir."""
    p = _norm(path)
    if p in ("", "/"):
        return True
    if is_home_like(p):
        return True
    segs = _segments(p)
    if len(segs) == 1 and ("/" + segs[0]) in _SYSTEM_ROOTS:
        return True
    return False


def looks_like_local_path_on_server(server_path) -> bool:
    """A macOS path used as the SERVER (Linux) destination. ``/Users/...`` does not
    exist on the Linux server — it only got created because a Mac path leaked into
    the server cwd. (``/home`` is a real Linux path, so it is NOT flagged here.)"""
    p = _norm(server_path)
    return p == "/Users" or p.startswith("/Users/")


def under_allowed_root(path, roots) -> bool:
    """True if ``path`` is one of ``roots`` or nested under one of them."""
    p = _norm(path)
    if not p:
        return False
    for r in roots or ():
        rn = _norm(r)
        if not rn:
            continue
        if p == rn or p.startswith(rn + os.sep):
            return True
    return False


def validate_server_path(server_path, cfg: SyncSafetyConfig) -> tuple:
    """Validate the SERVER (beta) endpoint. Run ON THE SERVER (``~`` = server home).
    Returns ``(ok, reason)``."""
    if is_dangerous_path(server_path):
        return False, f"refusing to sync a home/system directory on the server: {server_path!r}"
    if looks_like_local_path_on_server(server_path):
        return False, (f"server destination {server_path!r} looks like a Mac path "
                       "(it must be a server folder, e.g. under ~/codingprojects)")
    if not under_allowed_root(server_path, cfg.allowed_server_roots):
        return False, (f"server path {server_path!r} is outside the allowed roots "
                       f"{cfg.allowed_server_roots}")
    return True, ""


def validate_local_path(local_path, cfg: SyncSafetyConfig) -> tuple:
    """Validate the LOCAL (alpha) endpoint. Run ON THE MAC (``~`` = Mac home).
    Returns ``(ok, reason)``."""
    if is_dangerous_path(local_path):
        return False, f"refusing to sync a home/system directory: {local_path!r}"
    if not under_allowed_root(local_path, cfg.allowed_local_roots):
        return False, (f"folder {local_path!r} is outside your allowed sync roots "
                       f"{cfg.allowed_local_roots} — move it under a projects folder "
                       "or add its root to JC_SYNC_ALLOWED_LOCAL_ROOTS")
    return True, ""


def validate_endpoints_for_server_gate(local_path, server_path,
                                       cfg: SyncSafetyConfig) -> tuple:
    """The SERVER-side gate: fully validate the server path, and reject a clearly
    dangerous LOCAL path (home/``/``) by pattern (the allowed-local-root check is
    deferred to the client where Mac ``~`` resolves). Returns ``(ok, reason)``."""
    ok, reason = validate_server_path(server_path, cfg)
    if not ok:
        return ok, reason
    if is_dangerous_path(local_path):
        return False, f"refusing to sync a home/system directory: {local_path!r}"
    return True, ""


def estimate_tree(path, ignore_names, *, byte_cap, file_cap) -> tuple:
    """BOUNDED walk of ``path``: prunes ignored dir names + ``.git*``, and STOPS
    EARLY the moment a cap is exceeded (so it never walks a whole huge tree).

    Returns ``(total_bytes, total_files, exceeded)``. Symlinks are not followed.
    """
    ignore = set(ignore_names or ())
    root = os.path.expanduser(str(path or ""))
    total_bytes = 0
    total_files = 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [d for d in dirnames
                       if d not in ignore and not d.startswith(".git")]
        for fn in filenames:
            try:
                st = os.lstat(os.path.join(dirpath, fn))
            except OSError:
                continue
            total_bytes += st.st_size
            total_files += 1
            if total_bytes > byte_cap or total_files > file_cap:
                return total_bytes, total_files, True
    return total_bytes, total_files, False
