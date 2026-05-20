#!/usr/bin/env bash
# Build an iOS .ipa for TestFlight or ad-hoc install.
#
# Prerequisites:
#   - An Apple Developer account with the JarvisCopilot bundle ID
#     registered (com.jarviscopilot.mobile).
#   - The signing certificate + provisioning profile installed in
#     the Keychain (`fastlane match` is convenient if you script this).
#   - GoogleService-Info.plist dropped into ios/Runner/ for FCM/APNs.
#
# Usage:
#   ./scripts/build-ios.sh [--config Release] [--export-method app-store]
#
# Default export is "development"; pass `--export-method app-store` for
# TestFlight builds, or `--export-method ad-hoc` for direct UUID-keyed
# distribution.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="Release"
EXPORT_METHOD="development"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --export-method) EXPORT_METHOD="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

echo "→ Flutter build ($CONFIG)…"
flutter pub get
flutter build ios --release --no-codesign

echo "→ Archiving…"
xcodebuild -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -archivePath build/ios/Runner.xcarchive \
  archive

echo "→ Exporting IPA ($EXPORT_METHOD)…"
mkdir -p build/ios/ipa
cat > build/ios/exportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>${EXPORT_METHOD}</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
xcodebuild \
  -exportArchive \
  -archivePath build/ios/Runner.xcarchive \
  -exportPath build/ios/ipa \
  -exportOptionsPlist build/ios/exportOptions.plist

echo "✅ IPA ready at build/ios/ipa/"
