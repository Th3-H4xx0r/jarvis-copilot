#!/usr/bin/env bash
# Stop / Notification / UserPromptSubmit hook: tell JarvisCopilot the live coding
# session's activity_state changed THE MOMENT it happens, so the iOS Live Activity
# (APNs force-push) and the WebUI (SSE) update instantly instead of waiting for
# the server's 4-5s poll loop to rediscover it.
#   $1 = stop | notification | user_prompt_submit
# Fire-and-forget + always exit 0 so it never blocks or fails Claude. The client
# (`jc-client coding-event`) silently no-ops when unpaired. Works on BOTH hosts:
# a server-host hook reaches localhost; a Mac-host hook reaches the server over
# the jc-client tunnel.
event="${1:-stop}"
input="$(cat 2>/dev/null)"
sid="$(printf '%s' "$input" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("session_id") or "")
except Exception: print("")' 2>/dev/null)"
cwd="$(printf '%s' "$input" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("cwd") or "")
except Exception: print("")' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"
# The tmux session name is the server's primary join key to the session row.
# Target the hook's OWN pane ($TMUX_PANE): an untargeted display-message falls
# back to the most-recently-used session, which can be a DIFFERENT claude — the
# event (e.g. "waiting") would then be written onto the wrong session row.
tmux=""
if [ -n "$TMUX" ]; then
  if [ -n "$TMUX_PANE" ]; then
    tmux="$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null)"
  else
    tmux="$(tmux display-message -p '#S' 2>/dev/null)"
  fi
fi
( jc-client coding-event --event "$event" --tmux "$tmux" --cwd "$cwd" --session-id "$sid" >/dev/null 2>&1 & ) >/dev/null 2>&1 || true
exit 0
