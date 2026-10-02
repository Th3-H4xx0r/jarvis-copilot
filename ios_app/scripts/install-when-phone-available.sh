#!/bin/bash
# Poll for the paired iPhone and install + launch the already-built app when it appears.
# Usage: scripts/install-when-phone-available.sh [max_minutes]   (default 300)
cd "$(dirname "$0")/.."
DEVICE="${JC_PHONE_UDID:-00008150-001130180232401C}"   # Pranav's iPhone 17 Pro Max (devicectl now lists the UDID)
# Whichever device build is newest: deploy-both.sh builds Release, Xcode runs build Debug. A fixed
# Debug path once installed a week-old app over a fresh Release build.
APP=$(ls -dt build/dd/Build/Products/Release-iphoneos/JarvisCopilot.app \
             build/dd/Build/Products/Debug-iphoneos/JarvisCopilot.app 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "no built app under build/dd — run ./deploy-both.sh first" >&2; exit 1; }
echo "$(date '+%H:%M:%S') installing $APP (built $(stat -f '%Sm' "$APP"))"
BUNDLE_ID="com.jarviscopilot.jarviscopilotMobileAndIOS"
MAX=${1:-300}; LOG=build/install-watch.log
for ((i=0; i<MAX/2; i++)); do
  if xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | grep -q "available"; then
    echo "$(date '+%H:%M:%S') phone available, installing" | tee -a "$LOG"
    if xcrun devicectl device install app --device "$DEVICE" "$APP" >> "$LOG" 2>&1; then
      xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" >> "$LOG" 2>&1
      echo "$(date '+%H:%M:%S') INSTALLED AND LAUNCHED" | tee -a "$LOG"; exit 0
    fi
    echo "$(date '+%H:%M:%S') install failed, will retry" | tee -a "$LOG"
  fi
  sleep 120
done
echo "$(date '+%H:%M:%S') gave up after $MAX minutes" | tee -a "$LOG"; exit 1
