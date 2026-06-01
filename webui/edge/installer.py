"""Detect / install the ``cloudflared`` and ``nginx`` binaries.

Cross-platform (Linux + macOS + Windows): prefer the system package manager
(apt/dnf/pacman/zypper/apk on Linux, brew on macOS, winget/choco on Windows),
fall back to a direct per-arch binary download for cloudflared (which publishes
standalone binaries for every platform). nginx is installed via the package
manager only — building it from source is out of scope.

All shell-outs use argv lists (never ``shell=True``) and a fixed allowlist of
commands, so nothing here is influenced by request input. PATH is augmented so a
headless/service-spawned process still finds brew, the distro package manager,
and our own downloaded binary.
"""
from __future__ import annotations

import os
import platform
import shutil
import subprocess
from dataclasses import dataclass
from typing import List, Optional


@dataclass
class ToolStatus:
    name: str
    installed: bool
    path: Optional[str]
    version: Optional[str]


# Locations a GUI/launchd/setsid-spawned process won't have on PATH but where
# the tools actually live. macOS GUI apps inherit a minimal PATH that excludes
# Homebrew (/opt/homebrew on Apple Silicon, /usr/local on Intel), and our own
# binary download lands in ~/.local/bin.
def _extra_bin_dirs() -> List[str]:
    home = os.path.expanduser("~")
    if platform.system().lower() == "windows":
        return [
            os.path.join(os.environ.get("LOCALAPPDATA", home), "Programs", "cloudflared"),
            os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "cloudflared"),
            os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "nginx"),
            os.path.join(os.environ.get("ChocolateyInstall", r"C:\ProgramData\chocolatey"), "bin"),
        ]
    return [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",   # Apple Silicon brew
        "/usr/local/bin", "/usr/local/sbin",         # Intel brew + common
        "/usr/sbin", "/sbin",                        # nginx often lives here
        "/usr/bin", "/bin",
        os.path.join(home, ".local", "bin"),         # our cloudflared download
    ]


def _augmented_path() -> str:
    """Current PATH plus the known-good dirs above (deduped, order-preserving)."""
    seen, parts = set(), []
    for d in (os.environ.get("PATH", "").split(os.pathsep) + _extra_bin_dirs()):
        if d and d not in seen:
            seen.add(d)
            parts.append(d)
    return os.pathsep.join(parts)


def _which(name: str) -> Optional[str]:
    # Search the augmented PATH so we find brew/nginx/cloudflared even when the
    # server was spawned with a minimal environment (the #1 cause of "Install
    # does nothing").
    return shutil.which(name, path=_augmented_path())


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
    # Pass the augmented PATH to the child so e.g. `brew` can find its own
    # toolchain even when our parent process has a minimal environment.
    env = dict(os.environ)
    env["PATH"] = _augmented_path()
    return subprocess.run(
        argv, capture_output=True, text=True, timeout=timeout, check=False, env=env
    )


def _has(cmd: str) -> bool:
    return _which(cmd) is not None


def install(name: str) -> ToolStatus:
    """Install *name* ('cloudflared' or 'nginx'). Idempotent — returns status.

    Raises RuntimeError with the captured command output when the install was
    attempted but the binary still isn't found, OR when no install method is
    available — so the UI can show WHY instead of silently doing nothing
    (the server may run headless on a remote host the operator can't shell into).
    """
    if name not in ("cloudflared", "nginx"):
        raise ValueError(f"refusing to install unknown tool: {name!r}")

    existing = status(name)
    if existing.installed:
        return existing

    system = platform.system().lower()
    attempts: List[str] = []   # human-readable trail for the error message
    last_output = ""

    def _attempt(label: str, argv: List[str]) -> None:
        nonlocal last_output
        attempts.append(label)
        cp = _run(argv)
        if cp.returncode != 0:
            last_output = (cp.stderr or cp.stdout or "").strip()[-600:]

    # 1. Package managers first.
    #    - macOS: brew (no sudo).
    #    - Windows: winget / choco.
    #    - Linux: apt/dnf/pacman/zypper/apk. `sudo -n` (non-interactive) so a
    #      headless service either has passwordless sudo or fails cleanly with a
    #      message instead of hanging on a password prompt.
    if name == "cloudflared":
        # cloudflared ships per-arch standalone binaries — prefer the direct
        # download on every platform (no repo setup, no sudo). Package managers
        # are tried only as a secondary path below if the download didn't land.
        attempts.append("binary download")
        try:
            _download_cloudflared(system)
        except RuntimeError as exc:
            last_output = str(exc)[-600:]
    elif _has("brew"):
        _attempt("brew install", ["brew", "install", name])
    elif system == "windows":
        if _has("winget"):
            _attempt("winget install", ["winget", "install", "-e", "--silent",
                                        "--accept-package-agreements",
                                        "--accept-source-agreements", "nginx"])
        elif _has("choco"):
            _attempt("choco install", ["choco", "install", "-y", "nginx"])
    else:  # Linux package managers (nginx)
        if _has("apt-get"):
            _run(["sudo", "-n", "apt-get", "update"])
            _attempt("apt-get install", ["sudo", "-n", "apt-get", "install", "-y", "nginx"])
        elif _has("dnf"):
            _attempt("dnf install", ["sudo", "-n", "dnf", "install", "-y", "nginx"])
        elif _has("yum"):
            _attempt("yum install", ["sudo", "-n", "yum", "install", "-y", "nginx"])
        elif _has("pacman"):
            _attempt("pacman -S", ["sudo", "-n", "pacman", "-S", "--noconfirm", "nginx"])
        elif _has("zypper"):
            _attempt("zypper install", ["sudo", "-n", "zypper", "--non-interactive", "install", "nginx"])
        elif _has("apk"):
            _attempt("apk add", ["sudo", "-n", "apk", "add", "nginx"])

    after = status(name)
    if after.installed:
        return after

    # Still not installed — explain why (no method, or the method failed).
    if not attempts:
        if name == "nginx":
            raise RuntimeError(
                "No supported package manager found (looked for brew, winget, "
                "choco, apt-get, dnf, yum, pacman, zypper, apk). Install nginx "
                "manually on the host, then retry."
            )
        raise RuntimeError(
            f"Could not install {name}: no install method available on this host."
        )
    detail = f"Tried: {', '.join(attempts)}."
    if last_output:
        detail += f" Last error: {last_output}"
    else:
        detail += (
            " The command ran but the binary still isn't on PATH"
            " (it may need sudo, or PATH may differ for the server process)."
        )
    raise RuntimeError(detail)


def _cloudflared_url(system: str) -> Optional[str]:
    """Resolve the cloudflared release URL for this OS+arch, or None."""
    machine = platform.machine().lower()
    # Normalize the many arch spellings to cloudflared's release naming.
    if machine in ("amd64", "x86_64", "x64"):
        arch = "amd64"
    elif machine in ("arm64", "aarch64"):
        arch = "arm64"
    elif machine in ("armv7l", "armv6l", "arm"):
        arch = "arm"
    elif machine in ("i386", "i686", "x86"):
        arch = "386"
    else:
        arch = "amd64"  # safest default
    base = "https://github.com/cloudflare/cloudflared/releases/latest/download/"
    if system == "linux":
        return f"{base}cloudflared-linux-{arch}"
    if system == "darwin":
        # macOS ships a .tgz; only amd64/arm64 are published.
        macarch = "arm64" if arch == "arm64" else "amd64"
        return f"{base}cloudflared-darwin-{macarch}.tgz"
    if system == "windows":
        winarch = "arm64" if arch == "arm64" else ("386" if arch == "386" else "amd64")
        return f"{base}cloudflared-windows-{winarch}.exe"
    return None


def _download(url: str, dest: str) -> None:
    """Download *url* → *dest*, preferring curl, falling back to urllib."""
    if _has("curl"):
        cp = _run(["curl", "-fsSL", url, "-o", dest])
        if cp.returncode == 0 and os.path.exists(dest):
            return
    # Fallback: stdlib urllib (no curl on the host, or curl failed).
    import urllib.request
    with urllib.request.urlopen(url, timeout=120) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f)


def _download_cloudflared(system: str) -> None:
    """Best-effort standalone-binary install of cloudflared (no package mgr).

    Linux/Windows: a single binary. macOS: a .tgz to unpack. Lands in
    ~/.local/bin (POSIX) or %LOCALAPPDATA%\\Programs (Windows) — both covered by
    _extra_bin_dirs so status()/the supervisor find it afterward.
    """
    url = _cloudflared_url(system)
    if not url:
        return
    if system == "windows":
        dest_dir = os.path.join(
            os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), "Programs", "cloudflared"
        )
        bin_name = "cloudflared.exe"
    else:
        dest_dir = os.path.join(os.path.expanduser("~"), ".local", "bin")
        bin_name = "cloudflared"
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, bin_name)
    try:
        if url.endswith(".tgz"):
            tmp = dest + ".tgz"
            _download(url, tmp)
            _run(["tar", "-xzf", tmp, "-C", dest_dir])
            try:
                os.remove(tmp)
            except OSError:
                pass
        else:
            _download(url, dest)
    except Exception as exc:  # surface as install failure via status() miss
        raise RuntimeError(f"cloudflared download failed: {exc}") from exc
    try:
        if system != "windows":
            os.chmod(dest, 0o755)
    except OSError:
        pass
