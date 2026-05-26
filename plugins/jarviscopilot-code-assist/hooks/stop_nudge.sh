#!/usr/bin/env bash
# Stop: once per session, remind Claude to persist this session's coding work to
# JarvisCopilot before finishing. Keyed by the hook payload's session_id so it
# fires at most once per session (not on every stop).
input="$(cat 2>/dev/null)"
sid="$(printf '%s' "$input" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("session_id",""))
except Exception: print("")' 2>/dev/null)"
mark="${TMPDIR:-/tmp}/jarviscopilot_handoff_${sid:-default}"
if [ ! -f "$mark" ]; then
  : > "$mark" 2>/dev/null || true
  echo "Before finishing: persist this session to JarvisCopilot — call store_session_handoff (what you did, current state, open threads) and store_code_knowledge for any durable learnings (bugs/fixes/repo structure/gotchas/decisions)."
fi
