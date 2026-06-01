"""`jc-client tui` — run the Ink TUI locally, attached to the remote agent.

Starts the shared loopback PinnedProxy to the paired server, then launches the
existing ui-tui (Node/Ink) in its attach mode pointed at the proxy's
/api/tui/ws. Same code + full feature set as `jarviscopilot --tui`; the agent
runs on the server.
"""
from __future__ import annotations

import logging
import os
import shutil
import subprocess
from pathlib import Path

from jc_client import credentials
from jc_client._proxy import PinnedProxy

logger = logging.getLogger(__name__)


def gateway_attach_url(port: int) -> str:
    return f"ws://127.0.0.1:{port}/api/tui/ws"


def _uitui_dir() -> Path:
    # tui_launcher.py lives at <src>/desktop_client/jc_client/ → repo root = parents[2].
    return Path(__file__).resolve().parents[2] / "ui-tui"


def _dist_is_stale(uidir: Path, entry: Path) -> bool:
    """True if any ui-tui source file is newer than the built bundle.

    `jc-client update` does `git reset --hard`, which bumps changed files'
    mtimes, so a stale prebuilt bundle is detected and rebuilt on the next run
    instead of silently serving outdated UI (e.g. old branding)."""
    try:
        entry_mtime = entry.stat().st_mtime
        for sub in ("src", "packages"):
            base = uidir / sub
            if not base.exists():
                continue
            for p in base.rglob("*.ts*"):
                if "node_modules" in p.parts:
                    continue
                if p.stat().st_mtime > entry_mtime:
                    return True
        return False
    except OSError:
        return False


def _ensure_built(uidir: Path) -> str | None:
    """Return the entry.js path to run, building ui-tui if needed. None on failure."""
    entry = uidir / "dist" / "entry.js"
    if entry.exists() and not _dist_is_stale(uidir, entry):
        return str(entry)
    npm = shutil.which("npm")
    if not npm:
        print("jc-client tui: 'npm' not found — install Node.js to use the TUI.")
        return None
    if not (uidir / "node_modules").exists():
        print("Installing TUI dependencies (one-time) …")
        if subprocess.run([npm, "install"], cwd=str(uidir)).returncode != 0:
            print("jc-client tui: 'npm install' failed.")
            return None
    print("Building the TUI (one-time) …")
    if subprocess.run([npm, "run", "build"], cwd=str(uidir)).returncode != 0:
        print("jc-client tui: 'npm run build' failed.")
        return None
    return str(entry) if entry.exists() else None


def run_tui() -> int:
    creds = credentials.load()
    if not creds.paired:
        print("jc-client tui: not paired — run `jc-client pair` first.")
        return 1
    node = shutil.which("node")
    if not node:
        print("jc-client tui: 'node' not found — install Node.js to use the TUI.")
        return 1
    uidir = _uitui_dir()
    if not uidir.exists():
        print(f"jc-client tui: ui-tui not found at {uidir} — re-run the installer.")
        return 1
    entry = _ensure_built(uidir)
    if not entry:
        return 1

    proxy = PinnedProxy(creds.server_url, creds.cert_fingerprint, creds.cookie,
                        cf_client_id=creds.cf_client_id, cf_client_secret=creds.cf_client_secret)
    port = proxy.start()
    env = {**os.environ, "HERMES_TUI_GATEWAY_URL": gateway_attach_url(port)}
    try:
        result = subprocess.run([node, entry], cwd=str(uidir), env=env)
        return int(getattr(result, "returncode", 0) or 0)
    finally:
        proxy.shutdown()
