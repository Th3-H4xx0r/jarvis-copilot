#!/usr/bin/env bash
# Prints real git context to ground a session handoff. Run from the repo before
# writing the handoff, and weave the output into Session Metadata + Files touched.
cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || true
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "(not a git repo)"; exit 0
fi
echo "Branch: $(git branch --show-current 2>/dev/null || echo '(detached HEAD)')"
up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
if [ -n "$up" ]; then
  echo "Upstream: $up (ahead $(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?') / behind $(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo '?'))"
fi
echo "HEAD: $(git log -1 --format='%h %s' 2>/dev/null)"
echo
echo "Recent commits (newest first):"
git log --oneline -8 --no-decorate 2>/dev/null | sed 's/^/  - /'
echo
echo "Working tree:"
if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  echo "  clean"
else
  git status --porcelain 2>/dev/null | sed 's/^/  /'
fi
