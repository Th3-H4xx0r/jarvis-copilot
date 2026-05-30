#!/usr/bin/env bash
#
# deploy_both.sh — build & install BOTH the JarvisCopilot iPhone app AND the
# Apple Watch companion in RELEASE (production) config to the connected devices,
# one command, no Xcode. Standalone installs (devicectl) → keep working when the
# Mac is unplugged (until the dev profile expires, ~1yr on a paid team).
#
# WHY THIS IS WEIRD: xcodebuild's CLI can't build an *embedded* watchOS target —
# it always compiles the watch for iOS and fails. But the watch app MUST be
# embedded in Runner.app for iOS to register it as Runner's WCSession companion
# (isWatchAppInstalled=true), or the watch shows "iPhone not connected". So we:
#   1) build the watch for watchOS separately (works),
#   2) build Runner for iOS separately, with the watch DECOUPLED (works),
#   3) splice the watchOS app into Runner.app/Watch/ and re-sign Runner,
#   4) install Runner (gives iOS the companion) AND the watch app (so it's on the watch).
#
# Prereqs (one-time): cd mobile_client && flutter pub get && (cd ios && pod install)
# Both devices connected/paired, unlocked, Developer Mode on.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

WATCH_TARGET="JarvisWatch Watch App"
WATCH_OUT="$APP_DIR/ios/build/watch_release"

echo "▸ Detecting devices…"
DEV="$(xcrun devicectl list devices 2>/dev/null || true)"
RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
IPHONE_ID="${IPHONE_ID:-$(printf '%s\n' "$DEV" | grep -i iphone | grep -ioE "$RE" | head -1 || true)}"
WATCH_ID="${WATCH_ID:-$(printf '%s\n' "$DEV" | grep -i watch  | grep -ioE "$RE" | head -1 || true)}"
echo "  iPhone=$IPHONE_ID  Watch=$WATCH_ID"

echo "▸ [1/4] Build watch app (Release, watchOS)…"
rm -rf "$WATCH_OUT"; mkdir -p "$WATCH_OUT"
xcodebuild -project ios/Runner.xcodeproj -target "$WATCH_TARGET" -configuration Release -sdk watchos \
  -allowProvisioningUpdates CONFIGURATION_BUILD_DIR="$WATCH_OUT" build >/dev/null
WATCH_APP="$WATCH_OUT/$WATCH_TARGET.app"
[ -d "$WATCH_APP" ] || { echo "✗ watch build failed"; exit 1; }

echo "▸ [2/4] Build iPhone app (flutter build ios --release)…"
flutter build ios --release
RUNNER_APP="build/ios/iphoneos/Runner.app"
[ -d "$RUNNER_APP" ] || { echo "✗ Runner build failed"; exit 1; }

echo "▸ [3/4] Splice watch into Runner.app + re-sign…"
rm -rf "$RUNNER_APP/Watch"; mkdir -p "$RUNNER_APP/Watch"
cp -R "$WATCH_APP" "$RUNNER_APP/Watch/"
ENT="/tmp/jc_runner_ent.plist"; rm -f "$ENT"
codesign -d --entitlements :"$ENT" "$RUNNER_APP" 2>/dev/null || true
# re-sign Runner with the SAME cert it was built with (match common-name -> SHA), fallback to first dev cert
ORIG_CN="$(codesign -dvv "$RUNNER_APP" 2>&1 | sed -n 's/^Authority=\(Apple Development:.*\)$/\1/p' | head -1 || true)"
IDSHA="$(security find-identity -v -p codesigning | grep -F "$ORIG_CN" 2>/dev/null | grep -oE '[0-9A-F]{40}' | head -1 || true)"
[ -n "$IDSHA" ] || IDSHA="$(security find-identity -v -p codesigning | grep -m1 'Apple Development' | grep -oE '[0-9A-F]{40}' || true)"
[ -n "$IDSHA" ] || { echo "✗ no Apple Development signing identity found"; exit 1; }
echo "  re-signing Runner with: ${ORIG_CN:-<fallback>} ($IDSHA)"
ENT_ARG=(); [ -s "$ENT" ] && ENT_ARG=(--entitlements "$ENT")
codesign -f -s "$IDSHA" "${ENT_ARG[@]}" --generate-entitlement-der "$RUNNER_APP"
echo "  verifying signature…"; codesign --verify --strict --verbose=1 "$RUNNER_APP"
echo "  embedded watch present: $(ls -d "$RUNNER_APP/Watch/"*.app 2>/dev/null || echo NONE)"

echo "▸ [4/4] Install…"
[ -n "$IPHONE_ID" ] && { echo "  iPhone…"; xcrun devicectl device install app --device "$IPHONE_ID" "$RUNNER_APP"; }
[ -n "$WATCH_ID" ]  && { echo "  watch…";  xcrun devicectl device install app --device "$WATCH_ID" "$WATCH_APP"; }

echo "✓ Done. Foreground JarvisCopilot on the iPhone (log in), then open the watch app."
