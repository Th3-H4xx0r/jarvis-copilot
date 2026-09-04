#!/usr/bin/env bash
# Notification/Stop hook: ping the user's JarvisCopilot-connected messaging channel
# (Telegram/etc.) when Claude needs input ($1=notification) or finishes ($1=stop).
# Fire-and-forget + always exit 0 so it never blocks or fails Claude. The client
# (`jc-client notify`) decides whether to actually send (target + notify_events).
event="${1:-notification}"
input="$(cat 2>/dev/null)"
proj="$(basename "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null)"
msg="$(printf '%s' "$input" | python3 -c 'import sys,json
try: print((json.load(sys.stdin).get("message") or "")[:200])
except Exception: print("")' 2>/dev/null)"
if [ "$event" = "stop" ]; then
  text="✅ Claude finished — ${proj}"
else
  text="🔔 Claude needs you — ${proj}${msg:+: $msg}"
fi
( jc-client notify --event "$event" "$text" >/dev/null 2>&1 & ) >/dev/null 2>&1 || true
exit 0
