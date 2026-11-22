#!/bin/bash
# The Developer ID build of the Jarvis Mac app — what the Jarvis Glasses camera (a CoreMediaIO
# system extension inside Jarvis.app) needs before macOS will load it:
#   archive → export signed "Developer ID Application" (hardened runtime, secure timestamp, a
#   Developer ID provisioning profile for the system-extension entitlement) → notarize → staple
#   → install to /Applications (system extensions only activate from there) → open.
#
#   mac_app/scripts/build-developer-id.sh               all of it
#   mac_app/scripts/build-developer-id.sh --no-install  stop after stapling (zip in build/devid/)
#
# One-time setup:
#   1. A "Developer ID Application" certificate for team VY5CNF8734 in the login keychain
#      (Xcode → Settings → Accounts → the team → Manage Certificates… → + → Developer ID Application).
#   2. Xcode signed in to that team (the export makes the Developer ID provisioning profiles).
#   3. xcrun notarytool store-credentials jarvis-notary --apple-id <apple id> --team-id VY5CNF8734
#      (it asks for an app-specific password from account.apple.com).
# Then, once: Jarvis → Settings → Glasses camera → Install camera, and allow it in
# System Settings → General → Login Items & Extensions → Camera Extensions.
set -euo pipefail
cd "$(dirname "$0")/../JarvisMac"
TEAM=VY5CNF8734
PROFILE="${NOTARY_PROFILE:-jarvis-notary}"
OUT="${OUT:-build/devid}"
DD="${DD:-build/dd-devid}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%y%j%H%M)}"

security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM)" \
  || { echo "No 'Developer ID Application' certificate for team $TEAM in the keychain (setup step 1)."; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "No notarytool profile '$PROFILE' (setup step 3)."; exit 1; }

xcodegen generate --quiet
rm -rf "$OUT"
mkdir -p "$OUT"
ARCHIVE="$OUT/Jarvis.xcarchive"
# Written here, not kept as a file: the repo's .gitignore drops anything named export*.
EXPORT_OPTIONS="$OUT/DeveloperID.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$TEAM</string>
	<key>destination</key><string>export</string>
</dict>
</plist>
PLIST

echo "archiving build $BUILD_NUMBER…"
xcodebuild -project JarvisMac.xcodeproj -scheme Jarvis -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DD" -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=$TEAM CODE_SIGN_IDENTITY="Apple Development" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp JARVIS_ENTITLEMENTS=Jarvis-devid.entitlements \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive 2>&1 | grep -E "error:|\*\* ARCHIVE" | tail -30
[ -d "$ARCHIVE" ] || { echo "archive failed"; exit 1; }

echo "exporting with Developer ID…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$OUT/export" -allowProvisioningUpdates 2>&1 | grep -E "error:|\*\* EXPORT" | tail -30
APP="$OUT/export/Jarvis.app"
[ -d "$APP" ] || { echo "export failed"; exit 1; }
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" || { echo "not Developer ID-signed"; exit 1; }
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q system-extension.install \
  || { echo "the app lost its system-extension entitlement (no Developer ID profile with System Extension?)"; exit 1; }
[ -d "$APP/Contents/Library/SystemExtensions/com.jarviscopilot.mac.glassescamera.systemextension" ] \
  || { echo "the camera extension isn't embedded"; exit 1; }

echo "notarizing (a few minutes)…"
ditto -c -k --keepParent "$APP" "$OUT/Jarvis-notarize.zip"
SUBMIT="$(xcrun notarytool submit "$OUT/Jarvis-notarize.zip" --keychain-profile "$PROFILE" --wait 2>&1)"
echo "$SUBMIT" | tail -5
if ! echo "$SUBMIT" | grep -q "status: Accepted"; then
  ID="$(echo "$SUBMIT" | awk '/^  id:/ {print $2; exit}')"
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE"
  exit 1
fi
xcrun stapler staple "$APP"
spctl -a -vv "$APP"
# The same zip the in-app updater takes (scripts/publish-app-update.sh), stapled.
ditto -c -k --keepParent "$APP" "$OUT/Jarvis.zip"
echo "zip: $(cd "$OUT" && pwd)/Jarvis.zip"
echo "build: $BUILD_NUMBER"
[ "${1:-}" = "--no-install" ] && exit 0

pkill -x Jarvis 2>/dev/null || true
sleep 1
rm -rf /Applications/Jarvis.app
cp -R "$APP" /Applications/Jarvis.app
# One Jarvis only: an older copy in ~/Applications (build-app.sh's) goes to the Trash.
if [ -d "$HOME/Applications/Jarvis.app" ]; then
  mv "$HOME/Applications/Jarvis.app" "$HOME/.Trash/Jarvis-$(date +%s).app"
  echo "moved ~/Applications/Jarvis.app to the Trash"
fi
echo "installed /Applications/Jarvis.app"
open /Applications/Jarvis.app
