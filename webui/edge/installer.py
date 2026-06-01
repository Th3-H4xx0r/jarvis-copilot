"""Detect / install the ``cloudflared`` and ``nginx`` binaries.

Cross-platform (macOS + Linux), modeled on the project's existing
``ollama_bootstrap`` pattern: prefer the system package manager, fall back to a
direct signed-binary download for cloudflared (which publishes per-arch
binaries). nginx is installed via the package manager only — building it from
source is out of scope.

All shell-outs use argv lists (never ``shell=True``) and a fixed allowlist of
commands, so nothing here is influenced by request input.
"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
from dataclasses import dataclass
from typing import List, Optional

CLOUDFLARED_DL = {
    # (system, machine) -> download URL
    ("darwin", "arm64"): "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz",
    ("darwin", "x86_64"): "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz",
    ("linux", "x86_64"): "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64",
    ("linux", "aarch64"): "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64",
}


@dataclass
class ToolStatus:
    name: str
    installed: bool
    path: Optional[str]
    version: Optional[str]


def _which(name: str) -> Optional[str]:
    return shutil.which(name)


def _version(path: str, args: List[str]) -> Optional[str]:
    try:
        out = subprocess.run(
            [path, *args], capture_output=True, text=True, timeout=10, check=False
        )
        return (out.stdout or out.stderr or "").strip().splitlines()[0] if (out.stdout or out.stderr) else None
    except (OSError, subprocess.SubprocessError):
        return None


def status(name: str) -> ToolStatus:
    path = _which(name)
    if not path:
        return ToolStatus(name=name, installed=False, path=None, version=None)
    ver_args = ["--version"] if name == "cloudflared" else ["-v"]
    return ToolStatus(name=name, installed=True, path=path, version=_version(path, ver_args))


def _run(argv: List[str], timeout: int = 600) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)


def _has(cmd: str) -> bool:
    return _which(cmd) is not None


def install(name: str) -> ToolStatus:
    """Install *name* ('cloudflared' or 'nginx'). Idempotent — returns status."""
    if name not in ("cloudflared", "nginx"):
        raise ValueError(f"refusing to install unknown tool: {name!r}")

    existing = status(name)
    if existing.installed:
        return existing

    system = platform.system().lower()

    # 1. Package managers first.
    if _has("brew"):
        _run(["brew", "install", name])
    elif name == "nginx":
        if _has("apt-get"):
            _run(["sudo", "apt-get", "update"])
            _run(["sudo", "apt-get", "install", "-y", "nginx"])
        elif _has("dnf"):
            _run(["sudo", "dnf", "install", "-y", "nginx"])
        elif _has("pacman"):
            _run(["sudo", "pacman", "-S", "--noconfirm", "nginx"])
    elif name == "cloudflared":
        if _has("apt-get"):
            # Cloudflare's apt repo install is multi-step; try the direct .deb-less
            # binary download path which is simpler and arch-correct.
            _download_cloudflared(system)

    after = status(name)
    if after.installed:
        return after

    # 2. Fallback: direct binary download for cloudflared on any platform.
    if name == "cloudflared":
        _download_cloudflared(system)
    return status(name)


def _download_cloudflared(system: str) -> None:
    machine = platform.machine().lower()
    if machine in ("amd64",):
        machine = "x86_64"
    if machine in ("arm64",) and system == "linux":
        machine = "aarch64"
    url = CLOUDFLARED_DL.get((system, machine))
    if not url:
        return
    dest_dir = os.path.join(os.path.expanduser("~"), ".local", "bin")
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, "cloudflared")
    if not _has("curl"):
        return
    if url.endswith(".tgz"):
        tmp = dest + ".tgz"
        _run(["curl", "-fsSL", url, "-o", tmp])
        _run(["tar", "-xzf", tmp, "-C", dest_dir])
        try:
            os.remove(tmp)
        except OSError:
            pass
    else:
        _run(["curl", "-fsSL", url, "-o", dest])
    try:
        os.chmod(dest, 0o755)
    except OSError:
        pass
