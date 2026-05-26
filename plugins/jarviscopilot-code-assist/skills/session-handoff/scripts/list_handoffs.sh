#!/usr/bin/env bash
# List the session handoffs stored for the CURRENT project in JarvisCopilot's
# shared code-memory (newest first). Mirrors agent-toolkit's list_handoffs, but
# reads from the shared store instead of local files.
#   list_handoffs.sh [N]      # N = how many to show (default 5)
cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || true
limit="${1:-5}"
if ! command -v jc-client >/dev/null 2>&1; then
  echo "(jc-client not found — use the recall_session_handoff MCP tool instead)"
  exit 0
fi
jc-client code-memory recall --kind sessions --limit "$limit" 2>/dev/null \
  || echo "(no handoffs, or JarvisCopilot unavailable — pair with \`jc-client pair\`)"
