"""Sync safety: the one definition of which folders may be a sync endpoint.

Client side (Mac): validate the LOCAL alpha endpoint + bound the tree size BEFORE
starting Mutagen. The desktop is the only side that can stat the real tree, and
the only side where ``~`` expands to the Mac home.

The server (``agent/coding_sync_safety.py``) loads THIS file by path for the
shared predicates (``is_home_like``, ``is_dangerous_path``,
``under_allowed_root``, ``roots_from_env``) and adds only its own server-path
checks, so the two sides cannot drift. Keep it pure stdlib.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass

_DEFAULT_LOCAL_ROOTS = [
    "~/PranavFiles/coding-projects", "~/codingprojects",
    "~/code", "~/projects", "~/src", "~/dev",
]
_SYSTEM_ROOTS = (
    "/etc", "/var", "/usr", "/bin", "/sbin", "/lib", "/lib64", "/boot",
    "/dev", "/proc", "/sys", "/opt", "/srv", "/run", "/mnt", "/media",
)
_GiB = 1024 ** 3
_MiB = 1024 ** 2


@dataclass
class LocalSyncSafetyConfig:
    allowed_local_roots: list
    max_tree_bytes: int = 2 * _GiB
    max_file_bytes: int = 100 * _MiB
    max_files: int = 50_000

    @classmethod
    def from_env(cls, env=None) -> "LocalSyncSafetyConfig":
        env = env if env is not None else os.environ

        def _roots(key, default):
            return roots_from_env(env, key, default)

        def _int(key, default):
            try:
                return int(env.get(key) or default)
            except (TypeError, ValueError):
                return default

        return cls(
            allowed_local_roots=_roots("JC_SYNC_ALLOWED_LOCAL_ROOTS", _DEFAULT_LOCAL_ROOTS),
            max_tree_bytes=_int("JC_SYNC_MAX_TREE_BYTES", 2 * _GiB),
            max_file_bytes=_int("JC_SYNC_MAX_FILE_BYTES", 100 * _MiB),
            max_files=_int("JC_SYNC_MAX_FILES", 50_000),
        )


def roots_from_env(env, key, default) -> list:
    """A ``:``/``,``-separated root list from ``env[key]``, else ``default``."""
    raw = (env.get(key) or "").strip()
    if raw:
        parts = [p.strip() for p in re.split(r"[:,]", raw) if p.strip()]
        if parts:
            return parts
    return list(default)


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


def estimate_tree(path, ignore_names, *, byte_cap, file_cap) -> tuple:
    """Bounded walk: prune ignored dir names + ``.git*``, STOP EARLY once a cap is
    exceeded. Returns ``(total_bytes, total_files, exceeded)``."""
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


def check_local_sync(local_path, ignore_names, cfg: LocalSyncSafetyConfig) -> tuple:
    """Full client gate for the alpha endpoint. Returns ``(ok, reason)``.

    Order: dangerous (home/system) → allowed-root → bounded size estimate.
    """
    if is_dangerous_path(local_path):
        return False, f"refusing to sync a home/system directory: {local_path!r}"
    if not under_allowed_root(local_path, cfg.allowed_local_roots):
        return False, (f"{local_path!r} is outside your allowed sync roots "
                       f"{cfg.allowed_local_roots} (set JC_SYNC_ALLOWED_LOCAL_ROOTS "
                       "to add one)")
    if not os.path.isdir(os.path.expanduser(str(local_path or ""))):
        return True, ""  # nothing to size yet; let Mutagen handle a missing dir
    nbytes, nfiles, exceeded = estimate_tree(
        local_path, ignore_names,
        byte_cap=cfg.max_tree_bytes, file_cap=cfg.max_files)
    if exceeded:
        return False, (f"folder is too large to sync (> {cfg.max_tree_bytes} bytes "
                       f"or > {cfg.max_files} files at {local_path!r}) — add ignore "
                       "rules or pick a smaller folder")
    return True, ""
