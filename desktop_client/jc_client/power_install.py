"""One-time setup for keep-awake, Wake Mac and sudo autofill (needs admin once).

Installs, root-owned so nothing running as the user can change them:
* the jarvis-power helper (power_helper/jarvis_power.py) as a LaunchDaemon;
* jarvis-askpass (power_helper/jarvis_askpass.sh), and the /etc/sudo.conf line
  that makes sudo use it when there's no terminal.

The admin step uses the stored Mac password when the app passes it (sudo -S,
on stdin only), else macOS's own admin dialog.
"""
from __future__ import annotations

import os
import plistlib
import shlex
import socket
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

LABEL = "com.jarviscopilot.power"
HELPER_PATH = "/Library/PrivilegedHelperTools/com.jarviscopilot.power.py"
ASKPASS_PATH = "/Library/PrivilegedHelperTools/jarvis-askpass"
PLIST_PATH = f"/Library/LaunchDaemons/{LABEL}.plist"
SUDO_CONF = "/etc/sudo.conf"
SOCKET_PATH = "/var/run/com.jarviscopilot.power.sock"
_HERE = Path(__file__).resolve().parent / "power_helper"


def sudo_conf_with_askpass(text: str) -> str:
    """sudo.conf with our askpass line (replacing any other askpass), the rest kept."""
    line = f"Path askpass {ASKPASS_PATH}"
    out, placed = [], False
    for ln in text.splitlines():
        if ln.split()[:2] == ["Path", "askpass"]:
            if not placed:
                out.append(line)
                placed = True
            continue
        out.append(ln)
    if not placed:
        out.append(line)
    return "\n".join(out) + "\n"


def _plist(uid: int) -> bytes:
    return plistlib.dumps({
        "Label": LABEL,
        "ProgramArguments": ["/usr/bin/python3", "-I", HELPER_PATH, "--uid", str(uid)],
        "RunAtLoad": True,
        "KeepAlive": True,
    })


def _script(stage: Path) -> str:
    q = shlex.quote
    return "\n".join([
        "set -e",
        "install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools",
        f"install -m 644 -o root -g wheel {q(str(stage / 'helper.py'))} {q(HELPER_PATH)}",
        f"install -m 755 -o root -g wheel {q(str(stage / 'askpass'))} {q(ASKPASS_PATH)}",
        f"install -m 644 -o root -g wheel {q(str(stage / 'sudo.conf'))} {q(SUDO_CONF)}",
        f"launchctl bootout system/{LABEL} 2>/dev/null || true",
        f"install -m 644 -o root -g wheel {q(str(stage / 'power.plist'))} {q(PLIST_PATH)}",
        f"launchctl bootstrap system {q(PLIST_PATH)}",
    ]) + "\n"


def _applescript_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def install(password: Optional[str] = None) -> dict:
    with tempfile.TemporaryDirectory(prefix="jc-power-") as tmp:
        stage = Path(tmp)
        (stage / "helper.py").write_bytes((_HERE / "jarvis_power.py").read_bytes())
        (stage / "askpass").write_bytes((_HERE / "jarvis_askpass.sh").read_bytes())
        current = Path(SUDO_CONF).read_text() if os.path.exists(SUDO_CONF) else ""
        (stage / "sudo.conf").write_text(sudo_conf_with_askpass(current))
        (stage / "power.plist").write_bytes(_plist(os.getuid()))
        script = stage / "install.sh"
        script.write_text(_script(stage))
        if password:
            proc = subprocess.run(["/usr/bin/sudo", "-S", "-k", "-p", "", "/bin/sh", str(script)],
                                  input=password + "\n", capture_output=True, text=True, timeout=60)
        else:
            cmd = (f"do shell script {_applescript_str('/bin/sh ' + shlex.quote(str(script)))} "
                   "with administrator privileges")
            proc = subprocess.run(["/usr/bin/osascript", "-e", cmd], capture_output=True, text=True,
                                  timeout=300)
    if proc.returncode != 0:
        err = (proc.stderr or "").strip().splitlines()
        return {"ok": False, "error": err[-1] if err else f"exit {proc.returncode}"}
    return {"ok": True, **status()}


def status() -> dict:
    installed = os.path.exists(PLIST_PATH) and os.path.exists(HELPER_PATH)
    running = False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            s.connect(SOCKET_PATH)
            running = True
    except OSError:
        pass
    try:
        askpass = f"Path askpass {ASKPASS_PATH}" in Path(SUDO_CONF).read_text()
    except OSError:
        askpass = False
    return {"installed": installed, "running": running, "askpass": askpass}
