#!/bin/bash
# Build the iPhone app and publish it as an in-app update ("Update available" pops up on
# every paired iPhone; a closed app gets a banner).
#   ios_app/scripts/release.sh --notes "• Paste images into chat
#   • PDFs read natively"
#   ios_app/scripts/release.sh --no-publish        # just archive + export the IPA
# Every build gets a build number (UTC yyDDDHHMM) so the app can tell an older build
# from a newer one; BUILD_NUMBER=N overrides it. Builds the main checkout as it stands,
# uncommitted edits included.
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM="${TEAM:-VY5CNF8734}"
OUT="${OUT:-build/release}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%y%j%H%M)}"
notes="" publish=1
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) notes="$2"; shift 2 ;;
    --no-publish) publish=0; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
ruby scripts/sync-project.rb >/dev/null
mkdir -p "$OUT"
ARCHIVE="$OUT/JarvisCopilot.xcarchive"
echo "==> Archiving build $BUILD_NUMBER"
rm -rf "$ARCHIVE"
xcodebuild -project JarvisCopilot.xcodeproj -scheme JarvisCopilot -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive > "$OUT/archive.log" 2>&1 || { grep -E "error:" "$OUT/archive.log" | head -20; tail -15 "$OUT/archive.log"; exit 1; }

echo "==> Exporting development IPA"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>debugging</string>
<key>teamID</key><string>$TEAM</string>
<key>signingStyle</key><string>automatic</string>
<key>thinning</key><string>&lt;none&gt;</string>
</dict></plist>
EOF
rm -rf "$OUT/export"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates > "$OUT/export.log" 2>&1 \
  || { tail -30 "$OUT/export.log"; exit 1; }
IPA="$(ls "$OUT"/export/*.ipa | head -1)"
echo "ipa: $IPA"
echo "build: $BUILD_NUMBER"
[ "$publish" = 1 ] || exit 0
../scripts/publish-app-update.sh --platform ios --file "$IPA" --notes "$notes"
