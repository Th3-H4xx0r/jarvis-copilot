"""A Lightpanda browser per browser task, driven over CDP.

agent-browser's own ``--engine lightpanda`` launcher does not start current
Lightpanda builds, but ``lightpanda serve`` + ``agent-browser --cdp <url>`` works
(and Lightpanda is ~10x lighter than Chromium). Each browser task gets its own
``lightpanda serve`` on a free loopback port; cleanup stops it.
"""
from __future__ import annotations

import logging
import os
import shutil
import socket
import subprocess
import tempfile
import time
from typing import Dict, Optional

from tools.process_registry import ProcessRegistry

logger = logging.getLogger(__name__)

_START_TIMEOUT_S = 6.0


def binary() -> Optional[str]:
    """Path to the Lightpanda binary (``browser.lightpanda_path`` or PATH)."""
    try:
        from jarviscopilot_cli.config import read_raw_config
        configured = str((read_raw_config().get("browser") or {}).get("lightpanda_path") or "").strip()
        if configured and os.access(configured, os.X_OK):
            return configured
    except Exception:
        pass
    return shutil.which("lightpanda")


def available() -> bool:
    return binary() is not None


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _ready(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.3):
            return True
    except OSError:
        return False


def start(key: str) -> Dict[str, object]:
    """Start ``lightpanda serve`` for one browser task → ``{cdp_url, pid, port}``."""
    exe = binary()
    if not exe:
        raise RuntimeError("Lightpanda is not installed")
    port = _free_port()
    log = tempfile.NamedTemporaryFile(prefix="lightpanda-", suffix=".log", delete=False)
    proc = subprocess.Popen(
        [exe, "serve", "--host", "127.0.0.1", "--port", str(port)],
        stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True,
    )
    log.close()
    deadline = time.monotonic() + _START_TIMEOUT_S
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"Lightpanda exited at start (status {proc.returncode})")
        if _ready(port):
            logger.debug("lightpanda for %s on port %s (pid %s)", key, port, proc.pid)
            return {"cdp_url": f"http://127.0.0.1:{port}", "pid": proc.pid, "port": port}
        time.sleep(0.05)
    stop(proc.pid)
    raise RuntimeError("Lightpanda did not open its CDP port in time")


def stop(pid: Optional[int]) -> None:
    if not pid:
        return
    try:
        ProcessRegistry._terminate_host_pid(int(pid))
    except (ProcessLookupError, ValueError, PermissionError, OSError):
        logger.debug("lightpanda pid %s already gone", pid)
