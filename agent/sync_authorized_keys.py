"""Append a desktop client's sync SSH public key to ``authorized_keys``.

The coding-session sync (Mutagen on the desktop) SSHes to hermes through the
WS<->TCP relay. For that SSH to authenticate, the desktop's public key must be in
the server account's ``authorized_keys``. The desktop pushes its PUBLIC key over
the device bridge at pairing; this module applies it: validated, idempotent,
tagged so we only ever manage our own line, with correct permissions.

Pure + dependency-free so it is unit-tested against a tmp HOME.
"""
from __future__ import annotations

import os

# Marker appended to every key we manage, so re-pushing is idempotent and our
# lines are distinguishable from the user's own keys.
_TAG = "jarviscopilot-sync"
_VALID_PREFIXES = (
    "ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-nistp256 ",
    "ecdsa-sha2-nistp384 ", "ecdsa-sha2-nistp521 ", "sk-ssh-ed25519@",
)


def is_valid_pubkey(line: str) -> bool:
    """True if ``line`` looks like a single OpenSSH public key (not a private
    key, not multi-line, not shell junk)."""
    s = (line or "").strip()
    if not s or "\n" in s or "\r" in s:
        return False
    if not s.startswith(_VALID_PREFIXES):
        return False
    parts = s.split()
    # type + base64 body (+ optional comment)
    if len(parts) < 2 or len(parts[1]) < 20:
        return False
    return True


def _normalize_key(pubkey: str) -> str:
    """The dedupe identity = key type + body (ignore the trailing comment)."""
    parts = pubkey.strip().split()
    return " ".join(parts[:2])


def add_authorized_key(pubkey: str, *, home: str | None = None) -> dict:
    """Idempotently add ``pubkey`` to ``<home>/.ssh/authorized_keys``.

    Returns ``{"added": bool, "path": str}`` or ``{"error": str}``. Creates
    ``~/.ssh`` (0700) and the file (0600) if missing. A key whose type+body
    already appears (ours or the user's) is NOT re-added.
    """
    if not is_valid_pubkey(pubkey):
        return {"error": "invalid public key"}
    home = home or os.path.expanduser("~")
    ssh_dir = os.path.join(home, ".ssh")
    path = os.path.join(ssh_dir, "authorized_keys")
    body = _normalize_key(pubkey)
    tagged_line = f"{pubkey.strip()} # {_TAG}"

    try:
        os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
        try:
            os.chmod(ssh_dir, 0o700)
        except OSError:
            pass
        existing = ""
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as fh:
                existing = fh.read()
        # Already present (match on type+body, ignoring comment) → no-op.
        for ln in existing.splitlines():
            if _normalize_key(ln) == body:
                return {"added": False, "path": path}
        sep = "" if (not existing or existing.endswith("\n")) else "\n"
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(f"{sep}{tagged_line}\n")
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        return {"added": True, "path": path}
    except OSError as exc:
        return {"error": str(exc)}
