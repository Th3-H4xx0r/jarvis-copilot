#!/bin/bash
# Compile the app for the iOS simulator (no tests). Same env vars as test.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
ruby scripts/sync-project.rb >/dev/null || exit 1
DD="${DD:-build/dd-test}"; SIM="${SIM:-iPhone 17 Pro}"
LOG="$DD/build.log"; mkdir -p "$DD"
xcodebuild -project JarvisCopilot.xcodeproj -scheme JarvisCopilot \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO build > "$LOG" 2>&1
STATUS=$?
grep -E "error:|warning: unre|\*\* BUILD" "$LOG" | sort -u | tail -60
echo "exit=$STATUS (full log: $LOG)"
exit $STATUS
