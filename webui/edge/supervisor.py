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
    """Start *argv* detached with stdout/stderr to the log file. Cross-platform:
    POSIX uses a new session (setsid); Windows uses a detached process group."""
    cur = proc_status(name)
    if cur.running:
        return cur
    log = open(_logfile(name), "ab", buffering=0)
    # Augment PATH so the child (cloudflared/nginx) can find sibling tools even
    # when the WebUI was spawned with a minimal environment.
    env = dict(os.environ)
    env["PATH"] = installer._augmented_path()
    kwargs = dict(
        stdout=log,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        env=env,
    )
    if os.name == "nt":
        # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP — survive parent exit.
        kwargs["creationflags"] = 0x00000008 | 0x00000200
    else:
        # start_new_session=True == setsid: detach from the WebUI's process
        # group so it is not killed when the request thread / parent exits.
        kwargs["start_new_session"] = True
    proc = subprocess.Popen(argv, **kwargs)
    _pidfile(name).write_text(str(proc.pid), encoding="utf-8")
    return ProcStatus(name=name, running=True, pid=proc.pid)


def start_nginx(conf_path: str) -> ProcStatus:
    path = installer._which("nginx")
    if not path:
        raise RuntimeError("nginx is not installed")
    # -p gives nginx a prefix dir for its temp/log files inside the edge dir so
    # it does not need write access to the system nginx prefix.
    prefix = str(state._edge_dir())
    argv = [path, "-c", conf_path, "-p", prefix]
    # `daemon off;` keeps nginx in the foreground so our pidfile/Popen handle
    # tracks the real process. Windows nginx has no daemon mode (always
    # foreground), so the flag is POSIX-only.
    if os.name != "nt":
        argv += ["-g", "daemon off;"]
    return _spawn("nginx", argv)


def reload_nginx(conf_path: str) -> ProcStatus:
    """Apply a new nginx config to the running process without a full restart.

    `nginx -s reload` (same -c/-p) sends SIGHUP so workers pick up the new config
    gracefully. If reload fails (or nginx isn't actually running), fall back to a
    stop + fresh start so a config change always takes effect.
    """
    path = installer._which("nginx")
    if not path:
        raise RuntimeError("nginx is not installed")
    prefix = str(state._edge_dir())
    cur = proc_status("nginx")
    if cur.running:
        out = subprocess.run(
            [path, "-c", conf_path, "-p", prefix, "-s", "reload"],
            capture_output=True, text=True, timeout=15, check=False,
        )
        if out.returncode == 0:
            return cur
    # Reload didn't work (or wasn't running) — do a clean restart.
    stop("nginx")
    return start_nginx(conf_path)


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
        if os.name == "nt":
            # No process groups / SIGTERM on Windows — taskkill the tree.
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)],
                           capture_output=True, check=False)
        else:
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
    parts: list[str] = []
    p = _logfile(name)
    if p.exists():
        try:
            parts.extend(p.read_text(encoding="utf-8", errors="replace").splitlines())
        except OSError:
            pass
    # nginx may also have written to a separate error file before stderr logging
    # took over (or on older configs) — merge it so upstream/502 errors show up.
    if name == "nginx":
        err = state._edge_dir() / "nginx_error.log"
        if err.exists():
            try:
                lines_err = err.read_text(encoding="utf-8", errors="replace").splitlines()
                if lines_err:
                    parts.append("--- nginx_error.log ---")
                    parts.extend(lines_err)
            except OSError:
                pass
    return "\n".join(parts[-lines:])
