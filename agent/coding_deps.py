"""Best-effort auto-install of host dependencies for Coding Sessions.

A coding session runs ``claude`` inside a ``tmux`` session on the host. ``tmux``
is small and uncontroversial, so we auto-install it when missing (the user asked
for this) across the common package managers. ``claude`` is NOT auto-installed —
it needs an interactive login — so we only detect it and return a clear message.
"""
from __future__ import annotations

import os
import shutil
import subprocess


def _which(name: str) -> str | None:
    return shutil.which(name)


def _detect_tmux_installer() -> list[str] | None:
    """Return the argv to install tmux for the first package manager found."""
    if _which("apt-get"):
        return ["apt-get", "install", "-y", "tmux"]
    if _which("dnf"):
        return ["dnf", "install", "-y", "tmux"]
    if _which("yum"):
        return ["yum", "install", "-y", "tmux"]
    if _which("apk"):
        return ["apk", "add", "tmux"]
    if _which("pacman"):
        return ["pacman", "-S", "--noconfirm", "tmux"]
    if _which("zypper"):
        return ["zypper", "-n", "install", "tmux"]
    if _which("brew"):
        return ["brew", "install", "tmux"]
    return None


def _with_privilege(argv: list[str]) -> list[str]:
    """Prefix sudo -n when not already root and the manager needs privilege.

    brew must NOT be run under sudo; everything else needs root. ``sudo -n``
    never prompts — if a password is required it fails fast with a clear error.
    """
    if argv and argv[0] == "brew":
        return argv
    try:
        is_root = os.geteuid() == 0
    except AttributeError:  # pragma: no cover - non-POSIX
        is_root = False
    if not is_root and _which("sudo"):
        return ["sudo", "-n", *argv]
    return argv


def ensure_tmux(*, timeout: float = 180.0, runner=None) -> tuple[bool, str]:
    """Ensure ``tmux`` is available, installing it if missing.

    Returns ``(ok, detail)``. ``runner`` is injectable for tests (defaults to
    ``subprocess.run``); it receives ``(argv, env)`` and should raise on failure.
    """
    if _which("tmux"):
        return True, "tmux present"
    installer = _detect_tmux_installer()
    if not installer:
        return False, ("tmux is not installed and no supported package manager "
                       "(apt/dnf/yum/apk/pacman/zypper/brew) was found — install tmux manually.")
    argv = _with_privilege(installer)
    env = {**os.environ, "DEBIAN_FRONTEND": "noninteractive"}

    def _default_runner(a, e):
        subprocess.run(a, check=True, capture_output=True, text=True, timeout=timeout, env=e)

    run = runner or _default_runner
    try:
        run(argv, env)
    except Exception as e:  # install failed
        if _which("tmux"):
            return True, "tmux present (after install)"
        return False, (f"tmux auto-install via `{' '.join(argv)}` failed: {e}. "
                       "Install tmux manually on this host.")
    if _which("tmux"):
        return True, f"installed tmux via `{installer[0]}`"
    return False, "tmux still missing after the install attempt — install it manually."


def claude_status(resolve=None) -> tuple[bool, str]:
    """Detect the ``claude`` CLI (NOT auto-installed — needs interactive login)."""
    cmd = "claude"
    if resolve is not None:
        cmd = resolve()
    else:
        try:
            from agent.claude_code_client import _resolve_command

            cmd = _resolve_command()
        except Exception:
            pass
    if _which(cmd):
        return True, "claude present"
    return False, ("the `claude` CLI is not installed / on PATH on this host. "
                   "Install Claude Code and run `claude` once to log in.")
