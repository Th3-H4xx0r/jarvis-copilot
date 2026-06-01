"""Start / stop / status for cloudflared and nginx.

Hybrid lifecycle (mirrors the project's existing ``setsid`` gateway-start
fallback in commit f4b87): use a supervised detached subprocess that survives
the request thread. Process handles + last-known PID are tracked in-memory and
in a small pidfile under the edge dir so status survives a WebUI restart.

We deliberately do NOT use ``shell=True`` and only ever exec the resolved
binary path with a fixed argv built from validated config paths.
"""
from __future__ import annotations

import os
import signal
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

from . import installer, state


@dataclass
class ProcStatus:
    name: str
    running: bool
    pid: Optional[int]


def _pidfile(name: str) -> Path:
    return state._edge_dir() / f"{name}.pid"


def _logfile(name: str) -> Path:
    return state._edge_dir() / f"{name}.log"


def _read_pid(name: str) -> Optional[int]:
    p = _pidfile(name)
    if not p.exists():
        return None
    try:
        return int(p.read_text(encoding="utf-8").strip())
    except (ValueError, OSError):
        return None


def _alive(pid: Optional[int]) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def proc_status(name: str) -> ProcStatus:
    pid = _read_pid(name)
    if _alive(pid):
        return ProcStatus(name=name, running=True, pid=pid)
    return ProcStatus(name=name, running=False, pid=None)


def _spawn(name: str, argv: List[str]) -> ProcStatus:
    """Start *argv* detached (new session) with stdout/stderr to the log file."""
    cur = proc_status(name)
    if cur.running:
        return cur
    log = open(_logfile(name), "ab", buffering=0)
    # start_new_session=True == setsid: detach from the WebUI's process group so
    # it is not killed when the request thread / parent exits.
    proc = subprocess.Popen(
        argv,
        stdout=log,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    _pidfile(name).write_text(str(proc.pid), encoding="utf-8")
    return ProcStatus(name=name, running=True, pid=proc.pid)


def start_nginx(conf_path: str) -> ProcStatus:
    path = installer._which("nginx")
    if not path:
        raise RuntimeError("nginx is not installed")
    # -p gives nginx a prefix dir for its temp/log files inside the edge dir so
    # it does not need write access to the system nginx prefix.
    prefix = str(state._edge_dir())
    return _spawn("nginx", [path, "-c", conf_path, "-p", prefix, "-g", "daemon off;"])


def test_nginx(conf_path: str) -> tuple[bool, str]:
    """Run ``nginx -t`` to validate a config before (re)starting. (ok, output)."""
    path = installer._which("nginx")
    if not path:
        return False, "nginx is not installed"
    prefix = str(state._edge_dir())
    out = subprocess.run(
        [path, "-t", "-c", conf_path, "-p", prefix],
        capture_output=True, text=True, timeout=15, check=False,
    )
    return out.returncode == 0, (out.stderr or out.stdout or "").strip()


def start_cloudflared(conf_path: str, token: str) -> ProcStatus:
    path = installer._which("cloudflared")
    if not path:
        raise RuntimeError("cloudflared is not installed")
    if not token:
        raise RuntimeError("cloudflared tunnel token is not configured")
    # Token-based run; ingress rules come from the rendered config file.
    argv = [
        path, "tunnel", "--no-autoupdate",
        "--config", conf_path,
        "run", "--token", token,
    ]
    return _spawn("cloudflared", argv)


def stop(name: str) -> ProcStatus:
    pid = _read_pid(name)
    if _alive(pid):
        try:
            os.killpg(os.getpgid(pid), signal.SIGTERM)
        except OSError:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
    p = _pidfile(name)
    if p.exists():
        try:
            p.unlink()
        except OSError:
            pass
    return ProcStatus(name=name, running=False, pid=None)


def tail_log(name: str, lines: int = 100) -> str:
    p = _logfile(name)
    if not p.exists():
        return ""
    try:
        data = p.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(data[-lines:])
