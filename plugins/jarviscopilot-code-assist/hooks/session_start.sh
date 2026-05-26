#!/usr/bin/env bash
# SessionStart: make JarvisCopilot aware of this project and recall its
# code-memory (latest session handoff + durable knowledge). Whatever this
# prints to stdout is injected into Claude's context for the session.
cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || true
jc-client code-memory bootstrap 2>/dev/null || \
  echo "(jarviscopilot-code-assist: JarvisCopilot unavailable — pair with \`jc-client pair\` to enable cross-session code memory)"
