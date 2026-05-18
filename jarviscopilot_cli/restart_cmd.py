"""JarvisCopilot `restart` subcommand.

Restarts the WebUI and/or gateway services in one shot. Tries systemd first
(jarviscopilot-webui.service, jarviscopilot-gateway.service) so a fully
installed system works without elevated privileges; falls back to direct
process management when systemd isn't available or the unit isn't installed.

Invoked as:
    jarviscopilot restart            # both
    jarviscopilot restart webui      # just the web UI
    jarviscopilot restart gateway    # just the gateway
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import time
from typing import Optional


_WEBUI_PORT = 8787
_WEBUI_UNITS = ("jarviscopilot-webui.service", "hermes-webui.service")
_GATEWAY_UNITS = ("jarviscopilot-gateway.service", "hermes-gateway.service")


def _info(msg: str) -> None:
    print(f"[restart] {msg}", flush=True)


def _ok(msg: str) -> None:
    print(f"[restart] ✓ {msg}", flush=True)


def _warn(msg: str) -> None:
    print(f"[restart] ! {msg}", flush=True)


def _have_systemctl() -> bool:
    return sys.platform.startswith("linux") and shutil.which("systemctl") is not None


def _unit_installed(unit: str) -> bool:
    """True if the systemd unit file is present on disk (loaded or not).

    Uses `list-unit-files` rather than `status`, because `status` returns
    nonzero for stopped units even when they're installed — we want
    presence detection, not running detection.
    """
    if not _have_systemctl():
        return False
    try:
        r = subprocess.run(
            ["systemctl", "list-unit-files", "--no-pager", unit],
            capture_output=True, text=True, timeout=5,
        )
        return unit in r.stdout
    except Exception:
        return False


def _systemctl_restart(unit: str) -> bool:
    """Restart a unit, retrying with passwordless sudo if the bare call
    fails on permissions. Returns True iff one of the attempts succeeded.
    """
    if not _have_systemctl() or not _unit_installed(unit):
        return False
    for argv in (
        ["systemctl", "restart", unit],
        ["sudo", "-n", "systemctl", "restart", unit],
    ):
        try:
            rc = subprocess.call(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if rc == 0:
                return True
        except FileNotFoundError:
            continue
        except Exception:
            continue
    return False


def _try_systemctl_for_any(units: tuple) -> Optional[str]:
    """Try restarting each named unit in order; return the first one that
    succeeded, or None if none worked."""
    for unit in units:
        if _systemctl_restart(unit):
            return unit
    return None


# ---------------------------------------------------------------------------
# Non-systemd fallbacks
# ---------------------------------------------------------------------------

def _pids_on_tcp_port(port: int) -> set:
    """Best-effort enumerate PIDs listening on a TCP port. Linux-flavored —
    falls back to lsof if ss isn't present. Returns a set of int PIDs."""
    pids: set = set()
    if shutil.which("ss"):
        try:
            r = subprocess.run(
                ["ss", "-tlnpH", f"sport = :{port}"],
                capture_output=True, text=True, timeout=5,
            )
            for m in re.finditer(r"pid=(\d+)", r.stdout or ""):
                pids.add(int(m.group(1)))
        except Exception:
            pass
    if not pids and shutil.which("lsof"):
        try:
            r = subprocess.run(
                ["lsof", "-iTCP:" + str(port), "-sTCP:LISTEN", "-Pn", "-t"],
                capture_output=True, text=True, timeout=5,
            )
            for line in (r.stdout or "").splitlines():
                line = line.strip()
                if line.isdigit():
                    pids.add(int(line))
        except Exception:
            pass
    return pids


def _kill_pids(pids: set, *, signum: int = 15) -> int:
    """SIGTERM (default) the given PIDs, returning the count killed."""
    killed = 0
    for pid in pids:
        try:
            os.kill(pid, signum)
            killed += 1
        except ProcessLookupError:
            pass
        except PermissionError:
            # Try via sudo as a last resort
            try:
                rc = subprocess.call(
                    ["sudo", "-n", "kill", f"-{signum}", str(pid)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                if rc == 0:
                    killed += 1
            except Exception:
                pass
        except Exception:
            pass
    return killed


def _gateway_pids() -> set:
    """Find PIDs running a Hermes gateway. The gateway typically runs as
    `python -m jarviscopilot_cli.main gateway run [--replace]`; we match on the
    command-line so multiple python processes don't confuse us."""
    pids: set = set()
    if not shutil.which("pgrep"):
        return pids
    try:
        r = subprocess.run(
            ["pgrep", "-f", r"jarviscopilot_cli\.main\s+gateway\s+run"],
            capture_output=True, text=True, timeout=5,
        )
        for line in (r.stdout or "").splitlines():
            line = line.strip()
            if line.isdigit():
                pids.add(int(line))
    except Exception:
        pass
    return pids


# ---------------------------------------------------------------------------
# Restart targets
# ---------------------------------------------------------------------------

def _restart_webui() -> bool:
    _info("Restarting WebUI ...")
    unit = _try_systemctl_for_any(_WEBUI_UNITS)
    if unit:
        _ok(f"WebUI: systemctl restart {unit}")
        return True
    # No systemd unit installed (or systemctl missing) — fall back to killing
    # whatever's holding port 8787. The user will need to relaunch manually
    # (we can't know the install path generically; that's why we recommend
    # creating the systemd unit via the installer).
    pids = _pids_on_tcp_port(_WEBUI_PORT)
    if not pids:
        _warn(f"WebUI: nothing listening on :{_WEBUI_PORT} and no systemd unit found.")
        _warn("Start it manually with scripts/launch-webui.sh")
        return False
    _info(f"WebUI: no systemd unit, sending SIGTERM to PID(s) {sorted(pids)} on :{_WEBUI_PORT} ...")
    _kill_pids(pids, signum=15)
    time.sleep(2)
    still = _pids_on_tcp_port(_WEBUI_PORT)
    if still:
        _info(f"WebUI: still running, escalating to SIGKILL on {sorted(still)} ...")
        _kill_pids(still, signum=9)
    _warn("WebUI: stopped. Re-run scripts/launch-webui.sh (or install the systemd unit) to bring it back.")
    return True


def _restart_gateway() -> bool:
    _info("Restarting gateway ...")
    unit = _try_systemctl_for_any(_GATEWAY_UNITS)
    if unit:
        _ok(f"Gateway: systemctl restart {unit}")
        return True
    # No systemd unit — Hermes's gateway has a built-in --replace flag that
    # kills any existing gateway and starts a fresh one. We spawn it
    # detached so this command returns immediately while the new gateway
    # keeps running. sys.executable is the venv Python (the user invoked
    # us via the venv's `jarviscopilot` shim), so it has all Hermes deps.
    _info("Gateway: no systemd unit, spawning `gateway run --replace` ...")
    try:
        # Detach: new session + close FDs so the parent shell exit can't
        # hang up the child. Logs go to /dev/null since we don't know
        # where the user wants them; for managed logs install the unit.
        subprocess.Popen(
            [sys.executable, "-m", "jarviscopilot_cli.main", "gateway", "run", "--replace"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
        # Give the new gateway a beat to take over before we report success.
        time.sleep(1.5)
        if _gateway_pids():
            _ok("Gateway: respawned with --replace")
            return True
        _warn("Gateway: spawn succeeded but no gateway process is running yet. "
              "Check `journalctl` or run `jarviscopilot gateway run --replace` manually.")
        return False
    except Exception as exc:
        _warn(f"Gateway: spawn failed: {exc}")
        return False


# ---------------------------------------------------------------------------
# Public entry — registered as the `restart` subcommand handler.
# ---------------------------------------------------------------------------

def cmd_restart(args) -> int:
    target = (getattr(args, "restart_target", None) or "all").lower()
    if target not in ("all", "webui", "gateway"):
        _warn(f"Unknown target: {target}. Use one of: all, webui, gateway.")
        return 2

    ok_all = True
    if target in ("all", "webui"):
        ok_all = _restart_webui() and ok_all
    if target in ("all", "gateway"):
        ok_all = _restart_gateway() and ok_all
    return 0 if ok_all else 1
