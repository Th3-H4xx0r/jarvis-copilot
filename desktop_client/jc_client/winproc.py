"""Process handling on Windows for the agents link (roster, local runtime, CLI).

Never ``os.kill(pid, 0)`` here: on Windows ``os.kill`` with anything but a console control
event calls TerminateProcess — a liveness check would kill the session it checks.
"""
from __future__ import annotations

from typing import Optional

# Terminal hosts a session's process tree can sit under, and what the hooks call them.
_HOSTS = {"windowsterminal.exe": "windows-terminal", "code.exe": "vscode", "cursor.exe": "vscode",
          "conhost.exe": "console", "openconsole.exe": "console"}


def pid_alive(pid) -> bool:
    try:
        import psutil
        return bool(psutil.pid_exists(int(pid)))
    except Exception:  # noqa: BLE001
        return False


def terminate_tree(pid, grace: float = 5.0) -> None:
    """Terminate ``pid`` and its children (children first), then kill what's still there."""
    try:
        import psutil
        root = psutil.Process(int(pid))
        procs = list(root.children(recursive=True)) + [root]
    except Exception:  # noqa: BLE001 — gone already, or not ours
        return
    for p in procs:
        try:
            p.terminate()
        except Exception:  # noqa: BLE001
            pass
    try:
        _, alive = psutil.wait_procs(procs, timeout=grace)
    except Exception:  # noqa: BLE001
        alive = procs
    for p in alive:
        try:
            p.kill()
        except Exception:  # noqa: BLE001
            pass


def _host(proc) -> Optional[str]:
    """The terminal host up the parent chain (WindowsTerminal.exe, Code.exe…), at most 8 up."""
    p = proc
    for _ in range(8):
        try:
            p = p.parent()
        except Exception:  # noqa: BLE001
            return None
        if p is None:
            return None
        try:
            name = p.name()
        except Exception:  # noqa: BLE001
            return None
        if name.lower() in _HOSTS:
            return name
    return None


def terminal_from_pid(pid) -> dict:
    """The terminal a session runs in, from its environment and parents: the Mac's keys
    (``term_program``) plus ``wt_session``, ``exe`` and, under VS Code, ``window_pid``."""
    try:
        import psutil
        proc = psutil.Process(int(pid))
        env = proc.environ() or {}
    except Exception:  # noqa: BLE001
        return {}
    out: dict = {}
    host = _host(proc)
    if env.get("TERM_PROGRAM"):
        out["term_program"] = str(env["TERM_PROGRAM"])
    elif env.get("WT_SESSION") or (host and _HOSTS.get(host.lower()) == "windows-terminal"):
        out["term_program"] = "windows-terminal"
    if env.get("WT_SESSION"):
        out["wt_session"] = str(env["WT_SESSION"])
    if host:
        out["exe"] = host
    if env.get("VSCODE_PID"):
        try:
            out["window_pid"] = int(env["VSCODE_PID"])
        except ValueError:
            pass
    return out
