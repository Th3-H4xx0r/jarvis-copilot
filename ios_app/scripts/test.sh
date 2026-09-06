#!/bin/bash
# Run the XCTest suite on the iOS simulator.
#   scripts/test.sh                       # whole suite
#   scripts/test.sh ChatControllerTests   # one test class (or Class/testMethod)
# Env: DD=<derived data dir> (default build/dd-test); SIM=<simulator name>.
set -uo pipefail
cd "$(dirname "$0")/.."
ruby scripts/sync-project.rb >/dev/null || exit 1
DD="${DD:-build/dd-test}"
SIM="${SIM:-iPhone 17 Pro}"
LOG="$DD/test.log"; mkdir -p "$DD"
ARGS=(-project JarvisCopilot.xcodeproj -scheme JarvisCopilot \
      -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath "$DD" \
      CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO)
for f in "$@"; do ARGS+=(-only-testing:"JarvisCopilotTests/$f"); done
xcodebuild "${ARGS[@]}" test > "$LOG" 2>&1
STATUS=$?
# Compact report: compile errors, failing assertions, and the summary line.
grep -E "error:|Test Case .* (failed|passed)|Executed [0-9]+ tests?|\*\* TEST" "$LOG" \
  | grep -vE "^\s*$" | sort -u | tail -80
TOTAL=$(grep -E "Executed [0-9]+ tests?" "$LOG" | tail -1 | sed -E "s/.*Executed ([0-9]+) tests.*/\1/")
if [ "$STATUS" = 0 ] && [ "${TOTAL:-0}" = 0 ]; then echo "NO TESTS EXECUTED — treating as failure (filter typo or pbxproj mid-sync?)"; STATUS=1; fi
echo "exit=$STATUS (full log: $LOG)"
exit $STATUS
