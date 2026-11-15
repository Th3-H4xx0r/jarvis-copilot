#!/usr/bin/env bash
# Sync windows_app/ to the PC and run the test suite there (optionally filtered).
#   windows_app/scripts/pc-test.sh "FullyQualifiedName~Jarvis.Tests.Link"
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
"$here/sync-pc.sh"
filter="${1:-}"
if [ -n "$filter" ]; then
  ssh jc-pc "cd ~/src/jarvis-copilot; dotnet test windows_app/Jarvis.Tests -c Debug --nologo --filter \"$filter\""
else
  ssh jc-pc "cd ~/src/jarvis-copilot; dotnet test windows_app/Jarvis.Tests -c Debug --nologo"
fi
