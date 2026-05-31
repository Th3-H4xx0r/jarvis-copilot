"""Filesystem path containment + a non-overridable credential/system denylist.

The always-on guard that protects regardless of any OS sandbox. For writes to
not-yet-existing files, containment canonicalizes the deepest *existing*
ancestor so a symlinked parent can't be used to escape (openhuman policy.rs).
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Tuple

# Non-overridable credential/system path segments (matched case-insensitively).
FORBIDDEN_SEGMENTS = {
    ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".gcloud", ".docker", ".netrc",
    "keychains", "id_rsa", "id_ed25519",
}
FORBIDDEN_PREFIXES = ("/etc", "/root", "/boot", "/proc", "/sys")
# Windows DPAPI dirs (appear under .../Microsoft/{Protect,Credentials,Crypto,Vault})
FORBIDDEN_WIN = {"protect", "credentials", "crypto", "vault"}


def _segments(p: str):
    return [s.lower() for s in Path(p).parts]


def is_forbidden_path(path: str) -> bool:
    """True if the path touches a credential store or protected system dir.

    Checks both the expanded path and its realpath — the literal form catches
    "/etc/..." while realpath catches symlink escapes (and on macOS /etc itself
    is a symlink to /private/etc)."""
    expanded = os.path.expanduser(path)
    try:
        resolved = os.path.realpath(expanded)
    except Exception:
        resolved = expanded
    for candidate in (expanded, resolved):
        low = candidate.lower()
        segs = set(_segments(candidate))
        if segs & FORBIDDEN_SEGMENTS:
            return True
        for pre in FORBIDDEN_PREFIXES:
            if low == pre or low.startswith(pre + os.sep):
                return True
        if "microsoft" in segs and (segs & FORBIDDEN_WIN):
            return True
    return False


def deepest_existing(path: str) -> str:
    p = Path(os.path.expanduser(path)).absolute()
    while not p.exists() and p != p.parent:
        p = p.parent
    return str(p)


def is_within(path: str, root: str) -> bool:
    """True if `path` resolves within `root` (symlink-safe).

    For not-yet-existing targets, canonicalizes the deepest existing ancestor.
    """
    if not root:
        return True
    root_r = os.path.realpath(os.path.expanduser(root))
    target = os.path.expanduser(path)
    if os.path.exists(target):
        tr = os.path.realpath(target)
    else:
        tr = os.path.realpath(deepest_existing(target))
    try:
        return os.path.commonpath([tr, root_r]) == root_r
    except ValueError:
        return False  # different drives / relative-vs-absolute mismatch


def validate_path(path: str, root: str = "") -> Tuple[bool, str]:
    """Return (allowed, reason). Denies credential/system paths always, and
    (when `root` is given) paths that escape the workspace."""
    if is_forbidden_path(path):
        return False, "forbidden system/credential path"
    if root and not is_within(path, root):
        return False, "path escapes the workspace root"
    return True, ""
