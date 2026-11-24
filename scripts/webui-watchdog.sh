#!/bin/bash
# Restart the Jarvis web server when it stops answering. Live 2026-11-23: it froze silently 23:52-23:58 UTC
# (process alive, no replies) until he rebooted the box, and the SSH relay runs through it too. Run every
# minute by jarviscopilot-webui-watchdog.timer (scripts/systemd/). Three failed checks in a row (~3 minutes):
# dump every thread's stack into the journal first (kill -USR1, webui/server.py), then restart.
set -u
UNIT="${WATCHDOG_UNIT:-jarviscopilot-webui.service}"
URL="${WATCHDOG_URL:-https://127.0.0.1:8787/}"
STATE="${WATCHDOG_STATE:-/run/jarviscopilot-webui-watchdog.fails}"
LIMIT="${WATCHDOG_LIMIT:-3}"
CURL="${WATCHDOG_CURL:-curl}"
SYSTEMCTL="${WATCHDOG_SYSTEMCTL:-systemctl}"
KILL="${WATCHDOG_KILL:-kill}"
SLEEP="${WATCHDOG_SLEEP:-sleep}"

# A stopped or starting server isn't frozen: leave it to systemd.
if [ "$("$SYSTEMCTL" is-active "$UNIT")" != "active" ]; then
  echo 0 > "$STATE"
  exit 0
fi
code=$("$CURL" -sk -o /dev/null -w '%{http_code}' --max-time 20 "$URL" 2>/dev/null || true)
case "$code" in
  2??|3??|401|403) echo 0 > "$STATE"; exit 0 ;;
esac
fails=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$STATE"
echo "web server check failed (HTTP ${code:-none}), $fails in a row"
[ "$fails" -ge "$LIMIT" ] || exit 0

pid=$("$SYSTEMCTL" show "$UNIT" -p MainPID --value)
if [ -n "$pid" ] && [ "$pid" != "0" ]; then
  "$KILL" -USR1 "$pid" 2>/dev/null   # every thread's stack into the journal, to see where it was stuck
  "$SLEEP" 3
fi
echo "web server not answering for $fails checks: restarting $UNIT"
echo 0 > "$STATE"
"$SYSTEMCTL" restart "$UNIT"
