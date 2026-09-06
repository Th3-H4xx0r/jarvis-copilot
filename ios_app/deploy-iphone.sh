#!/bin/bash
# Build, sign and install JarvisCopilot on the paired iPhone.
#
# Uses Xcode's automatic signing. This replaced hand-signing against the wildcard
# provisioning profile: wildcard App IDs cannot carry a push entitlement, so APNs —
# and therefore prompt background delivery of Jarvis commands — was impossible under
# the old scheme.
set -euo pipefail
cd "$(dirname "$0")"

DEVICE="$(xcrun devicectl list devices 2>/dev/null | grep -i iphone | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1)"   # Pranav's iPhone 17 Pro Max (coredevice UUID; the old ECID-style id stopped resolving 2026-09-05)
BUNDLE_ID="com.jarviscopilot.jarviscopilotMobileAndIOS"
APP="build/dd/Build/Products/Release-iphoneos/JarvisCopilot.app"

echo "==> Building (automatic signing)"
# ENABLE_DEBUG_DYLIB=NO keeps everything in one binary. Xcode 16+ otherwise splits the
# app into a thin launcher plus JarvisCopilot.debug.dylib for previews, and dyld
# refuses to load the app on device if any nested Mach-O is unsigned.
xcodebuild -project JarvisCopilot.xcodeproj -scheme JarvisCopilot \
  -destination 'generic/platform=iOS' -configuration Release \
  -derivedDataPath build/dd \
  -allowProvisioningUpdates \
  ENABLE_DEBUG_DYLIB=NO \
  build > /tmp/jw-build.log 2>&1 || { tail -30 /tmp/jw-build.log; exit 1; }

echo "==> Verifying push entitlement"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "aps-environment"; then
  echo "    aps-environment present"
else
  echo "    WARNING: no aps-environment — silent push will not be delivered"
fi

echo "==> Installing"
xcrun devicectl device install app --device "$DEVICE" "$APP" | tail -3

echo "==> Launching"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" | tail -2
