#!/bin/bash
# Build the Jarvis Mac app (notch island + menu bar) and install it.
#   mac_app/build-app.sh            # build, test-free, install to ~/Applications, (re)launch
#   mac_app/build-app.sh --test     # run the app's unit tests instead
# Needs Xcode and xcodegen (brew install xcodegen). Signs with the Apple
# Development identity of team 3CLSKGFAC9 (project.yml).
set -euo pipefail
cd "$(dirname "$0")/JarvisMac"
xcodegen generate --quiet
DD="${DD:-build/dd}"
if [ "${1:-}" = "--test" ]; then
  xcodebuild -project JarvisMac.xcodeproj -scheme Jarvis -destination 'platform=macOS' \
    -derivedDataPath "$DD" test 2>&1 | \
    grep -E "error:|Test Case .* (failed|passed)|Executed [0-9]+ tests?|\*\* TEST" | sort -u | tail -60
  exit "${PIPESTATUS[0]}"
fi
xcodebuild -project JarvisMac.xcodeproj -scheme Jarvis -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DD" build 2>&1 | grep -E "error:|warning: .*Jarvis|\*\* BUILD" | tail -40
APP="$DD/Build/Products/Release/Jarvis.app"
[ -d "$APP" ] || { echo "build failed: no $APP"; exit 1; }
DEST="$HOME/Applications/Jarvis.app"
mkdir -p "$HOME/Applications"
pkill -x Jarvis 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "installed $DEST"
open "$DEST"
