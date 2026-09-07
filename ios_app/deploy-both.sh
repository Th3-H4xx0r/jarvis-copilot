#!/bin/bash
# Build, sign and install BOTH the JarvisCopilot iPhone app AND the Apple Watch
# app, in Release, to the connected devices — one command, no Xcode.
#
# Ported from the old Flutter client's scripts/deploy_both.sh. Two things are
# different here, both because this project embeds the watch properly:
#
#   * The old script had to build the watch separately and splice it into the
#     app, because xcodebuild's CLI compiled an embedded watch target for iOS
#     and failed. The JarvisWatch target in this project is a real dependency of
#     the app with an Embed Watch Content phase, so one build produces
#     JarvisCopilot.app/Watch/JarvisWatch.app already signed. We VERIFY that
#     rather than splicing.
#   * The watch install is best-effort. Installing the iPhone app is what makes
#     iOS treat the watch app as its WCSession companion, and iOS pushes it to
#     the paired watch on its own; a direct install just makes it immediate.
#
# Prereqs: both devices paired, unlocked, Developer Mode on.
set -euo pipefail
cd "$(dirname "$0")"

RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
BUNDLE_ID="com.jarviscopilot.jarviscopilotMobileAndIOS"
APP="build/dd/Build/Products/Release-iphoneos/JarvisCopilot.app"
WATCH_APP="$APP/Watch/JarvisWatch.app"

echo "==> Detecting devices"
DEV="$(xcrun devicectl list devices 2>/dev/null || true)"
IPHONE_ID="${IPHONE_ID:-$(printf '%s\n' "$DEV" | grep -i iphone | grep -ioE "$RE" | head -1 || true)}"
WATCH_ID="${WATCH_ID:-$(printf '%s\n' "$DEV" | grep -i watch  | grep -ioE "$RE" | head -1 || true)}"
echo "    iPhone=${IPHONE_ID:-<none>}  Watch=${WATCH_ID:-<none>}"
[ -n "$IPHONE_ID" ] || { echo "✗ no iPhone connected — unlock it and check Developer Mode"; exit 1; }

echo "==> Building (automatic signing; the watch builds as a dependency)"
# ENABLE_DEBUG_DYLIB=NO keeps everything in one binary. Xcode 16+ otherwise splits
# the app into a thin launcher plus a .debug.dylib for previews, and dyld refuses
# to load the app on device if any nested Mach-O is unsigned.
xcodebuild -project JarvisCopilot.xcodeproj -scheme JarvisCopilot \
  -destination 'generic/platform=iOS' -configuration Release \
  -derivedDataPath build/dd \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  ENABLE_DEBUG_DYLIB=NO \
  build > /tmp/jw-build.log 2>&1 || { tail -30 /tmp/jw-build.log; exit 1; }

echo "==> Verifying push entitlement"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "aps-environment"; then
  echo "    aps-environment present"
else
  echo "    WARNING: no aps-environment — silent push will not be delivered"
fi

echo "==> Verifying the embedded watch app"
if [ -d "$WATCH_APP" ]; then
  # A watch app accidentally compiled for iOS is the classic failure here, and it
  # installs fine while leaving the watch saying "iPhone not connected".
  PLATFORM="$(plutil -extract CFBundleSupportedPlatforms.0 raw "$WATCH_APP/Info.plist" 2>/dev/null || echo unknown)"
  echo "    $(basename "$WATCH_APP") built for $PLATFORM"
  [ "$PLATFORM" = "WatchOS" ] || echo "    WARNING: expected WatchOS — the watch will not register as the companion"
else
  echo "    WARNING: no embedded watch app; only the iPhone app will be installed"
fi

echo "==> Installing on the iPhone"
xcrun devicectl device install app --device "$IPHONE_ID" "$APP" | tail -3

echo "==> Launching"
xcrun devicectl device process launch --device "$IPHONE_ID" --terminate-existing "$BUNDLE_ID" | tail -2

if [ -n "$WATCH_ID" ] && [ -d "$WATCH_APP" ]; then
  echo "==> Installing on the Apple Watch (best effort)"
  if ! xcrun devicectl device install app --device "$WATCH_ID" "$WATCH_APP" 2>/tmp/jw-watch-install.log; then
    echo "    Direct watch install did not take:"
    sed -n '1,3p' /tmp/jw-watch-install.log | sed 's/^/      /'
    echo "    This is normally harmless — the iPhone app embeds the watch app, so iOS"
    echo "    pushes it to the paired watch itself. Give it a moment, then open JARVIS"
    echo "    on the watch (or the Watch app on the iPhone to install it by hand)."
    echo "    If it never appears, it is provisioning, not the build:"
    echo "      1) On the watch: Settings > Privacy & Security > Developer Mode > On, then restart."
    echo "      2) Xcode > Window > Devices and Simulators > your Watch > 'Ready for development'."
  fi
else
  [ -n "$WATCH_ID" ] || echo "==> No watch connected; iOS will install it when the watch is next in range"
fi

echo "✓ Done."
