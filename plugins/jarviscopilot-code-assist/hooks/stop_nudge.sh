#!/usr/bin/env bash
# Stop: a cadence-based memory-review nudge (mirrors the JarvisCopilot agent's
# every-N-turns background review — NOT per-turn). The Stop hook fires when
# Claude finishes a response; we count fires per session and nudge every 5th, so
# durable learnings get captured without nagging on every turn.
input="$(cat 2>/dev/null)"
sid="$(printf '%s' "$input" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("session_id",""))
except Exception: print("")' 2>/dev/null)"
counter="${TMPDIR:-/tmp}/jarviscopilot_cmreview_${sid:-default}"
n="$(cat "$counter" 2>/dev/null || echo 0)"
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
printf '%s' "$n" > "$counter" 2>/dev/null || true
if [ $((n % 5)) -eq 0 ]; then
  echo "Memory check (every few turns): if you learned anything durable since the last check — a non-obvious bug/fix, repo structure, a gotcha, or a decision — store it now via store_code_knowledge as a SHORT declarative fact (skip run-specific results). If you're wrapping up, call store_session_handoff (what you did, current state, open threads)."
fi
