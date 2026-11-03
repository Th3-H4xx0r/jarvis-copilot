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
# Wake Mac's push needs the aps entitlement, so a provisioning profile: Xcode makes
# one only with an Apple ID in Settings → Accounts. Without one (or an existing Mac
# profile for com.jarviscopilot.mac) keep the manual, profile-free signing and the
# Mac still wakes on its 15-minute timer. PUSH=0/1 forces either way.
SIGN=()
if [ -z "${PUSH:-}" ]; then
  PUSH=0
  if defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null | grep -q '@' \
     || grep -lq "com.jarviscopilot.mac<" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile 2>/dev/null; then
    PUSH=1
  fi
fi
if [ "$PUSH" = 1 ]; then
  SIGN=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration CODE_SIGN_STYLE=Automatic
        DEVELOPMENT_TEAM=VY5CNF8734 CODE_SIGN_IDENTITY="Apple Development"
        CODE_SIGN_ENTITLEMENTS=Jarvis-push.entitlements)
  echo "signing: automatic, with Wake Mac push"
else
  echo "signing: manual, no push (add an Apple ID in Xcode → Settings → Accounts for Wake Mac push)"
fi
if [ "${1:-}" = "--test" ]; then
  xcodebuild -project JarvisMac.xcodeproj -scheme Jarvis -destination 'platform=macOS' \
    -derivedDataPath "$DD" ${SIGN[@]+"${SIGN[@]}"} test 2>&1 | \
    grep -E "error:|Test Case .* (failed|passed)|Executed [0-9]+ tests?|\*\* TEST" | sort -u | tail -60
  exit "${PIPESTATUS[0]}"
fi
xcodebuild -project JarvisMac.xcodeproj -scheme Jarvis -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DD" ${SIGN[@]+"${SIGN[@]}"} CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build 2>&1 | \
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
