"""Fetch + install the Mutagen binary the coding-session sync engine needs.

jc-client updates via ``git pull`` + ``pip install -e`` (not a frozen bundle),
so rather than ship a per-platform binary we download the pinned Mutagen release
into the client state dir (``~/.jarviscopilot-client/bin/mutagen``) on demand:
``jc-client update`` refreshes it, and a sync start self-heals if it's missing.

Idempotent: if the right version is already installed, it's a no-op. Integrity:
the download is over HTTPS and we verify the tarball's SHA-256 against the
release ``SHA256SUMS`` (best-effort) AND that the installed binary self-reports
the pinned version before we trust it.

The pure helpers (platform/asset naming) and ``ensure_mutagen`` (with an
injectable ``opener``) are unit-tested without network.
"""
from __future__ import annotations

import hashlib
import io
import logging
import os
import platform
import subprocess
import sys
import tarfile
from typing import Callable, Optional, Tuple

log = logging.getLogger(__name__)

PINNED_MUTAGEN_VERSION = "0.18.1"
_RELEASE_BASE = "https://github.com/mutagen-io/mutagen/releases/download/v{v}/{asset}"
_DOWNLOAD_TIMEOUT = 120


def _exe_name() -> str:
    return "mutagen.exe" if sys.platform.startswith("win") else "mutagen"


def platform_target() -> Tuple[Optional[str], Optional[str]]:
    """(os, arch) for the Mutagen asset, or (None, None) if unsupported."""
    if sys.platform == "darwin":
        osn = "darwin"
    elif sys.platform.startswith("linux"):
        osn = "linux"
    elif sys.platform.startswith("win"):
        osn = "windows"
    else:
        osn = None
    m = (platform.machine() or "").lower()
    if m in ("arm64", "aarch64"):
        arch = "arm64"
    elif m in ("x86_64", "amd64"):
        arch = "amd64"
    elif m in ("i386", "i686", "x86"):
        arch = "386"
    else:
        arch = None
    return osn, arch


def asset_name(version: str, osn: str, arch: str) -> str:
    return f"mutagen_{osn}_{arch}_v{version}.tar.gz"


def asset_url(version: str, osn: str, arch: str) -> str:
    return _RELEASE_BASE.format(v=version, asset=asset_name(version, osn, arch))


def sha256sums_url(version: str) -> str:
    return _RELEASE_BASE.format(v=version, asset="SHA256SUMS")


def bin_dir(state_dir: str) -> str:
    return os.path.join(state_dir, "bin")


def installed_path(state_dir: str) -> Optional[str]:
    """Path to a usable cached mutagen binary, or None."""
    p = os.path.join(bin_dir(state_dir), _exe_name())
    if os.path.isfile(p) and os.access(p, os.X_OK):
        return p
    return None


def installed_version(path: str) -> Optional[str]:
    """``mutagen version`` (just the number) or None."""
    try:
        out = subprocess.run([path, "version"], capture_output=True, text=True,
                             timeout=10)
        if out.returncode == 0:
            return (out.stdout or "").strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None


# opener(url) -> bytes
Opener = Callable[[str], bytes]


def _default_opener(url: str) -> bytes:
    import urllib.request
    req = urllib.request.Request(url, headers={"User-Agent": "jc-client/mutagen-install"})
    with urllib.request.urlopen(req, timeout=_DOWNLOAD_TIMEOUT) as resp:
        return resp.read()


def _expected_sha256(sums_text: str, asset: str) -> Optional[str]:
    for line in sums_text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and os.path.basename(parts[-1]) == asset:
            return parts[0].lower()
    return None


def _extract_binary(tar_bytes: bytes, dest_dir: str) -> None:
    """Extract ``mutagen``(.exe) + ``mutagen-agents.tar.gz`` from the release
    tarball into ``dest_dir`` (path-traversal safe). The agents bundle MUST sit
    next to the binary for Mutagen to deploy its remote agent."""
    wanted = {_exe_name(), "mutagen", "mutagen-agents.tar.gz"}
    os.makedirs(dest_dir, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:gz") as tf:
        for member in tf.getmembers():
            base = os.path.basename(member.name)
            if not member.isfile() or base not in wanted:
                continue
            src = tf.extractfile(member)
            if src is None:
                continue
            out = os.path.join(dest_dir, base)
            with open(out, "wb") as fh:
                fh.write(src.read())


def ensure_mutagen(state_dir: str, *, version: str = PINNED_MUTAGEN_VERSION,
                   opener: Optional[Opener] = None,
                   log_fn: Optional[Callable[[str], None]] = None) -> str:
    """Ensure the pinned Mutagen binary is installed under ``state_dir``; return
    its path. No-op if already at the right version. Raises RuntimeError on an
    unsupported platform or a failed/again-wrong install."""
    say = log_fn or (lambda _m: None)
    target = os.path.join(bin_dir(state_dir), _exe_name())

    if os.path.isfile(target):
        v = installed_version(target)
        if v and v.lstrip("v") == version:
            return target

    osn, arch = platform_target()
    if not osn or not arch:
        raise RuntimeError(
            f"unsupported platform for Mutagen: {sys.platform}/{platform.machine()}")

    op = opener or _default_opener
    asset = asset_name(version, osn, arch)
    say(f"Downloading Mutagen {version} ({asset}) …")
    data = op(asset_url(version, osn, arch))

    # Best-effort SHA-256 verification against the release SHA256SUMS.
    try:
        sums = op(sha256sums_url(version)).decode("utf-8", "replace")
        expected = _expected_sha256(sums, asset)
        if expected:
            actual = hashlib.sha256(data).hexdigest()
            if actual != expected:
                raise RuntimeError(
                    f"Mutagen download checksum mismatch ({actual} != {expected})")
    except RuntimeError:
        raise
    except Exception as exc:  # noqa: BLE001 — sums fetch is best-effort
        log.debug("Mutagen SHA256SUMS verify skipped: %s", exc)

    _extract_binary(data, bin_dir(state_dir))
    if not os.path.isfile(target):
        raise RuntimeError("Mutagen tarball did not contain the expected binary")
    try:
        os.chmod(target, 0o755)
    except OSError:
        pass

    v = installed_version(target)
    if not v or v.lstrip("v") != version:
        raise RuntimeError(
            f"installed mutagen reports {v!r}, expected {version}")
    say(f"Mutagen {version} installed → {target}")
    return target
