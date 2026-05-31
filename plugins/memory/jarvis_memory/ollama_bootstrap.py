"""Auto-provision Ollama for the default (local) embedder.

On `jarviscopilot memory setup` (post_setup) this installs Ollama if missing,
starts the server as a detached background process, and pulls the embedding
model. At runtime (provider initialize) it only *starts* an already-installed
server if it's down — never installs or pulls on the hot path.

All operations are best-effort and degrade gracefully: if anything fails, recall
falls back to keyword-only and a hint is logged/printed.
"""
from __future__ import annotations

import json
import logging
import os
import platform
import shutil
import subprocess
import time
import urllib.request

logger = logging.getLogger(__name__)

DEFAULT_URL = "http://localhost:11434"

_LOCAL_HOSTS = {"localhost", "127.0.0.1", "0.0.0.0", "::1", ""}


def is_local_url(url: str) -> bool:
    """True only for a local Ollama. We must never try to install/spawn a server
    for a REMOTE url (e.g. when the gateway points at an Ollama on another host)
    — that's what caused Ollama to keep launching on the user's laptop."""
    from urllib.parse import urlparse
    try:
        host = (urlparse(url).hostname or "").lower()
    except Exception:
        host = ""
    return host in _LOCAL_HOSTS


def is_running(url: str = DEFAULT_URL, timeout: float = 1.5) -> bool:
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/api/tags", timeout=timeout):
            return True
    except Exception:
        return False


def is_installed() -> bool:
    return shutil.which("ollama") is not None


def install(printer=logger.info) -> bool:
    if is_installed():
        return True
    sysname = platform.system()
    try:
        if sysname == "Darwin" and shutil.which("brew"):
            printer("Installing Ollama via Homebrew (one-time)…")
            subprocess.run(["brew", "install", "ollama"], check=True)
        elif sysname in ("Darwin", "Linux"):
            printer("Installing Ollama via the official install script (one-time)…")
            subprocess.run("curl -fsSL https://ollama.com/install.sh | sh",
                           shell=True, check=True)
        else:
            printer(f"Automatic Ollama install isn't supported on {sysname}; "
                    "install it from https://ollama.com/download")
            return False
    except Exception as e:
        printer(f"Ollama install failed: {e}. Install manually from https://ollama.com/download")
        return False
    return is_installed()


def start_server(url: str = DEFAULT_URL, wait_secs: float = 12.0) -> bool:
    if is_running(url):
        return True
    if not is_local_url(url):
        return False  # remote Ollama — never spawn a local server
    if not is_installed():
        return False
    try:
        subprocess.Popen(
            ["ollama", "serve"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,  # detach so it outlives this process group
        )
    except Exception as e:
        logger.warning("failed to start ollama serve: %s", e)
        return False
    deadline = time.monotonic() + wait_secs
    while time.monotonic() < deadline:
        if is_running(url):
            return True
        time.sleep(0.5)
    return is_running(url)


def has_model(model: str) -> bool:
    try:
        out = subprocess.run(["ollama", "list"], capture_output=True, text=True, timeout=15).stdout
        return model.split(":")[0] in out
    except Exception:
        return False


def pull_model(model: str, printer=logger.info) -> bool:
    if has_model(model):
        return True
    try:
        printer(f"Pulling embedding model '{model}' (one-time download, ~1.2GB)…")
        subprocess.run(["ollama", "pull", model], check=True)
    except Exception as e:
        printer(f"Failed to pull '{model}': {e}. Run 'ollama pull {model}' manually.")
        return False
    return has_model(model)


def setup(model: str = "bge-m3", url: str = DEFAULT_URL, printer=logger.info) -> bool:
    """Full provisioning for setup time: install + start + pull.

    For a REMOTE url, never install/spawn locally — just verify reachability
    (the model must be pulled on the server that runs Ollama)."""
    if not is_local_url(url):
        if is_running(url):
            printer(f"Using remote Ollama at {url} (no local install).")
            return True
        printer(f"Remote Ollama at {url} is not reachable — start it on that host "
                f"and pull '{model}' there.")
        return False
    if not install(printer):
        return False
    if not start_server(url):
        printer("Ollama installed but the server didn't start; try 'ollama serve'.")
        return False
    return pull_model(model, printer)


def ensure_running(url: str = DEFAULT_URL) -> bool:
    """Runtime: start an already-installed LOCAL server if it's down. Never
    spawns for a remote url (just reports reachability). No install/pull."""
    if is_running(url):
        return True
    if not is_local_url(url):
        return False  # remote — can't/shouldn't start it here
    if is_installed():
        return start_server(url)
    return False
