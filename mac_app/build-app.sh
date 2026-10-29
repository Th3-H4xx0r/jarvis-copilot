#!/bin/bash
# Build the Jarvis Mac app (notch island + menu bar) and install it.
#   mac_app/build-app.sh            # build, test-free, install to ~/Applications, (re)launch
#   mac_app/build-app.sh --test     # run the app's unit tests instead
#   mac_app/build-app.sh --package  # build, zip to JarvisMac/build/package/Jarvis.zip for
#                                   # scripts/publish-app-update.sh (no install)
# Every build gets CFBundleVersion = UTC yyDDDHHMM (env BUILD_NUMBER overrides):
# the in-app updater offers only a higher build than the one running.
# Needs Xcode and xcodegen (brew install xcodegen). Signs with the Apple
# Development identity of team 3CLSKGFAC9 (project.yml).
set -euo pipefail
cd "$(dirname "$0")/JarvisMac"
xcodegen generate --quiet
DD="${DD:-build/dd}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%y%j%H%M)}"
if [ "${1:-}" = "--test" ]; then
  xcodebuild -project JarvisMac.xcodeproj -scheme Jarvis -destination 'platform=macOS' \
    -derivedDataPath "$DD" test 2>&1 | \
    grep -E "error:|Test Case .* (failed|passed)|Executed [0-9]+ tests?|\*\* TEST" | sort -u | tail -60
  exit "${PIPESTATUS[0]}"
fi
xcodebuild -project JarvisMac.xcodeproj -scheme Jarvis -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DD" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build 2>&1 | \
  grep -E "error:|warning: .*Jarvis|\*\* BUILD" | tail -40
APP="$DD/Build/Products/Release/Jarvis.app"
[ -d "$APP" ] || { echo "build failed: no $APP"; exit 1; }
if [ "${1:-}" = "--package" ]; then
  BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
  [ "$BUILT" = "$BUILD_NUMBER" ] || { echo "build failed: $APP is build $BUILT, not $BUILD_NUMBER"; exit 1; }
  OUT="${OUT:-build/package}"
  mkdir -p "$OUT"
  rm -f "$OUT/Jarvis.zip"
  ditto -c -k --keepParent "$APP" "$OUT/Jarvis.zip"
  echo "zip: $(cd "$OUT" && pwd)/Jarvis.zip"
  echo "build: $BUILT"
  echo "version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  exit 0
fi
DEST="$HOME/Applications/Jarvis.app"
mkdir -p "$HOME/Applications"
pkill -x Jarvis 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "installed $DEST"
open "$DEST"
