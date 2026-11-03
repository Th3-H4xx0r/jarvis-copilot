#!/bin/sh
# jarvis-askpass: sudo's askpass helper (`Path askpass` in /etc/sudo.conf, set by
# jc_client/power_install.py). sudo runs it as the user when it needs the password
# and there's no terminal (Claude Code's commands) or with -A. It asks jc-client,
# which asks Pranav (iPhone Face ID or Mac Touch ID); only on his yes does the
# Jarvis Mac app hand back the password, printed here for sudo. Anything else:
# exit 1 (sudo then fails like a wrong password, nothing typed anywhere).
exec /usr/bin/python3 -I - "$PPID" <<'PY'
import json, os, socket, subprocess, sys

ppid = sys.argv[1]
try:
    command = subprocess.run(["/bin/ps", "-o", "command=", "-p", ppid], capture_output=True,
                             text=True, timeout=5).stdout.strip()
except Exception:
    command = ""
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(150)
try:
    sock.connect(os.path.expanduser("~/.jarviscopilot-client/ui.sock"))
    sock.sendall((json.dumps({"type": "password_request", "id": 1, "kind": "sudo",
                              "command": command[:500], "ppid": int(ppid)}) + "\n").encode())
    for line in sock.makefile("r", encoding="utf-8"):
        msg = json.loads(line)
        if msg.get("type") != "reply" or msg.get("id") != 1:
            continue
        if msg.get("ok") and msg.get("password"):
            sys.stdout.write(msg["password"] + "\n")
            sys.exit(0)
        break
except Exception:
    pass
sys.stderr.write("Jarvis: not approved\n")
sys.exit(1)
PY
