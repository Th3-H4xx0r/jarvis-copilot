#!/bin/bash
# Real Live Activities in the simulator, screenshotted — the widget's own renderer,
# which in-app render tests are not (LiveActivityLayoutProbeTests).
#   scripts/la-probe.sh <sim-id> <workout|agent|dashcam> [state]
#     states: run rest lift cycle-paused yoga | approval question question-open working | dc-both dc-up dc-last
# Each state comes up with an alert over the home screen: an iPhone 16e (no island)
# draws the Lock Screen layout as a banner; an island iPhone draws the expanded
# island. simctl screenshots miss the island: open Xcode's DeviceHub and pass its
# window id as WIN=<id> to capture that window instead. Run `xcodebuild
# build-for-testing` (derivedDataPath build/dd-test) first. Shots go to $OUT.
SIM=$1 SET=$2 ONLY=${3:-}
OUT=${OUT:-build/la-probe}; mkdir -p "$OUT"
cd "$(dirname "$0")/.."
LOG=$OUT/$SET-$ONLY.log
TEST_RUNNER_JC_LA_PROBE=1 TEST_RUNNER_JC_LA_SET=$SET TEST_RUNNER_JC_LA_ONLY=$ONLY xcodebuild test-without-building \
  -project JarvisCopilot.xcodeproj -scheme JarvisCopilot -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build/dd-test CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO -collect-test-diagnostics never \
  -only-testing:JarvisCopilotTests/LiveActivityLayoutProbeTests > "$LOG" 2>&1 &
PID=$!
backgrounded=0; done_shots=""
while kill -0 $PID 2>/dev/null; do
  if [ $backgrounded = 0 ] && grep -q "PROBE ready" "$LOG"; then
    sleep 1; xcrun simctl launch "$SIM" com.apple.Preferences >/dev/null 2>&1; backgrounded=1
  fi
  for name in $(grep -o "PROBE shot [a-z-]*" "$LOG" | awk '{print $3}'); do
    case " $done_shots " in *" $name "*) ;; *)
      if [ -n "${WIN:-}" ]; then screencapture -x -o -l "$WIN" "$OUT/$name.png"
      else xcrun simctl io "$SIM" screenshot "$OUT/$name.png" >/dev/null 2>&1; fi
      done_shots="$done_shots $name";;
    esac
  done
  sleep 0.5
done
echo "shots:$done_shots (in $OUT)"
