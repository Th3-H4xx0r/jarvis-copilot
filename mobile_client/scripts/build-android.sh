#!/usr/bin/env bash
# Build a signed Android APK for side-loading.
#
# Prerequisites:
#   - android/key.properties pointing at your release keystore:
#       storePassword=…
#       keyPassword=…
#       keyAlias=…
#       storeFile=/path/to/release.jks
#   - google-services.json dropped into android/app/ for FCM.
#
# Usage:
#   ./scripts/build-android.sh [--debug]
#
# The default builds a release APK. Pass --debug to get the dev build
# (useful for confirming the FCM token plumbing without dealing with
# signing).

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then CONFIG="debug"; fi

echo "→ Flutter build ($CONFIG)…"
flutter pub get
if [[ "$CONFIG" == "release" ]]; then
  flutter build apk --release --split-per-abi
else
  flutter build apk --debug
fi

OUT_DIR=build/app/outputs/flutter-apk
echo "✅ APKs at $OUT_DIR/"
ls -la "$OUT_DIR/"
