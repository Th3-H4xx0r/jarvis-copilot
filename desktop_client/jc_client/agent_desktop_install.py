"""Install the pinned agent-desktop release (vercel-labs/agent-desktop) for computer control.

agent-desktop reads and acts on desktop apps through the OS accessibility tree. jc-client runs
it behind ``ui_look``/``ui_do`` (the PC's main engine; the Mac's for Electron apps and menus).
The release archive is pinned by SHA-256 here — a version bump is a code change — and checked
before anything is written, so a tampered or truncated download installs nothing.
"""
from __future__ import annotations

import hashlib
import io
import os
import platform
import shutil
import sys
import tarfile
import tempfile
from typing import Callable, Optional

PINNED_VERSION = "1.3.1"
_RELEASE_BASE = "https://github.com/vercel-labs/agent-desktop/releases/download/v{v}/{asset}"
_DOWNLOAD_TIMEOUT = 120
# (sys.platform, platform.machine()) → (release asset, its SHA-256 from the release's checksums.txt).
ASSETS: dict = {
    ("darwin", "arm64"): ("agent-desktop-v1.3.1-aarch64-apple-darwin.tar.gz",
                          "9b7b7cfc74892eab46c2c85d6cb7dc4863bf8dab0a222cfcfb8ae4604c69c86c"),
    ("win32", "AMD64"): ("agent-desktop-v1.3.1-x86_64-pc-windows-msvc.tar.gz",
                         "6ee4b1e078f4e78792e79f16e32e4a78b9919464aa3c55629b7e27ed53a08c13"),
    ("win32", "ARM64"): ("agent-desktop-v1.3.1-aarch64-pc-windows-msvc.tar.gz",
                         "805f1f61890f9983fceaf38cda94a37a049c379435d65607db5cedd22c8ef97b"),
}
# Only these leave the archive (the macOS helper must sit beside the binary).
_MEMBERS = ("agent-desktop", "agent-desktop.exe", "agent-desktop-macos-helper")


def _exe(plat: str) -> str:
    return "agent-desktop.exe" if plat.startswith("win") else "agent-desktop"


def _dir(state_dir: str) -> str:
    return os.path.join(state_dir, "bin", f"agent-desktop-{PINNED_VERSION}")


def installed_path(state_dir: str, *, plat: Optional[str] = None) -> Optional[str]:
    """The installed binary, or None."""
    path = os.path.join(_dir(state_dir), _exe(plat or sys.platform))
    return path if os.path.isfile(path) else None


def _default_opener(url: str) -> bytes:
    import urllib.request
    req = urllib.request.Request(url, headers={"User-Agent": "jc-client/agent-desktop-install"})
    with urllib.request.urlopen(req, timeout=_DOWNLOAD_TIMEOUT) as resp:
        return resp.read()


def ensure_agent_desktop(state_dir: str, *, opener: Optional[Callable[[str], bytes]] = None,
                         log_fn: Optional[Callable[[str], None]] = None, plat: Optional[str] = None,
                         machine: Optional[str] = None) -> Optional[str]:
    """Install the pinned release under ``state_dir`` (no-op when present); its path, or None
    on a platform with no pinned build. Raises ValueError on a checksum mismatch."""
    plat = plat or sys.platform
    machine = machine or platform.machine()
    have = installed_path(state_dir, plat=plat)
    if have:
        return have
    pinned = ASSETS.get((plat, machine))
    if not pinned:
        return None
    asset, sha = pinned
    (log_fn or (lambda _m: None))(f"Downloading agent-desktop {PINNED_VERSION} ({asset}) …")
    data = (opener or _default_opener)(_RELEASE_BASE.format(v=PINNED_VERSION, asset=asset))
    if hashlib.sha256(data).hexdigest() != sha:
        raise ValueError("agent-desktop checksum mismatch")
    dest = _dir(state_dir)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".agent-desktop-", dir=os.path.dirname(dest))
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
            for member in tf.getmembers():
                base = os.path.basename(member.name)
                if not member.isfile() or base not in _MEMBERS:
                    continue
                src = tf.extractfile(member)
                if src is None:
                    continue
                out = os.path.join(tmp, base)
                with open(out, "wb") as fh:
                    fh.write(src.read())
                os.chmod(out, 0o755)
        if not os.path.isfile(os.path.join(tmp, _exe(plat))):
            raise ValueError("agent-desktop archive has no binary")
        if os.path.isdir(dest):
            shutil.rmtree(dest)
        os.replace(tmp, dest)
    finally:
        if os.path.isdir(tmp):
            shutil.rmtree(tmp, ignore_errors=True)
    return installed_path(state_dir, plat=plat)
