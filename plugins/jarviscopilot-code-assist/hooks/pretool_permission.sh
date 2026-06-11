#!/usr/bin/env bash
# PreToolUse hook: relay a tool-permission prompt to JarvisCopilot mobile for a
# remote Approve / Deny / Reply. Whatever `jc-client coding-permission` prints
# (the PreToolUse `permissionDecision` JSON) becomes this hook's stdout, which
# Claude applies; printing NOTHING lets Claude use its normal permission flow.
#
# Always exits 0 so it can never break Claude. The relay is gated server-side by
# the `remote_approvals` setting and falls back to the local prompt when it's
# off, the phone is unreachable, or no verdict arrives in time — so it never
# auto-approves and never hangs an at-the-terminal session.
input="$(cat 2>/dev/null)"

get() {
  printf '%s' "$input" | python3 -c 'import sys, json
try:
    print(json.load(sys.stdin).get(sys.argv[1]) or "")
except Exception:
    print("")' "$1" 2>/dev/null
}

tool="$(get tool_name)"
mode="$(get permission_mode)"
cwd="$(get cwd)"
sid="$(get session_id)"
tinput="$(printf '%s' "$input" | python3 -c 'import sys, json
try:
    print(json.dumps(json.load(sys.stdin).get("tool_input") or {}))
except Exception:
    print("{}")' 2>/dev/null)"

# Only relay when Claude would actually prompt (default mode). In
# bypassPermissions / acceptEdits / plan modes, defer silently — never hang or
# hijack a session that isn't going to prompt anyway.
[ "$mode" = "default" ] || exit 0
[ -n "$tool" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

tmux=""
if [ -n "$TMUX" ]; then
  tmux="$(tmux display-message -p '#S' 2>/dev/null)"
fi

# Blocking: its stdout is the permissionDecision JSON Claude reads.
jc-client coding-permission --tool "$tool" --input "$tinput" \
  --tmux "$tmux" --cwd "$cwd" --session-id "$sid" --timeout 120 2>/dev/null || true
exit 0
