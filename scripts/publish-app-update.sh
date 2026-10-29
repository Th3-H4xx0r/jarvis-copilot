#!/bin/bash
# Publish an app build to the Jarvis server so the apps pop up "Update available".
#   scripts/publish-app-update.sh --platform ios --file JarvisCopilot.ipa --notes "• line one"
#   scripts/publish-app-update.sh --platform mac --file Jarvis.zip --notes "..."
#   scripts/publish-app-update.sh --platform ios --rollback     # previous build becomes current
# The build number is read from the archive's own Info.plist. The file streams over
# ssh to the server, where `python -m api.app_updates upload` hands it to the running
# WebUI (host-signed, localhost), which stores it and tells the apps.
set -euo pipefail
HOST="${JC_SERVER_SSH:-jc-hermes}"
REMOTE="${JC_SERVER_DIR:-/root/JarvisCopilot}"
platform="" file="" notes="" rollback=0
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="$2"; shift 2 ;;
    --file) file="$2"; shift 2 ;;
    --notes) notes="$2"; shift 2 ;;
    --rollback) rollback=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$platform" in ios|mac) ;; *) echo "--platform ios|mac is required" >&2; exit 2 ;; esac

if [ "$rollback" = 1 ]; then
  # Stops devices still on the older build from being offered the bad one; a phone that
  # already installed it needs a new, higher build to get off it.
  ssh "$HOST" "cd $REMOTE/webui && ../.venv/bin/python -m api.app_updates rollback --platform $platform"
  exit 0
fi

[ -f "$file" ] || { echo "--file must be an existing .ipa or .zip" >&2; exit 2; }
build=$(python3 - "$file" "$platform" <<'PY'
import plistlib, re, sys, zipfile
pattern = r"^Payload/[^/]+\.app/Info\.plist$" if sys.argv[2] == "ios" else r"^[^/]+\.app/Contents/Info\.plist$"
with zipfile.ZipFile(sys.argv[1]) as zf:
    name = next(n for n in zf.namelist() if re.match(pattern, n))
    print(plistlib.loads(zf.read(name))["CFBundleVersion"])
PY
)
size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file")
commit=$(git -C "$(dirname "$0")/.." rev-parse --short HEAD 2>/dev/null || true)
echo "==> Publishing $platform build $build ($((size / 1048576)) MB) to $HOST"
ssh "$HOST" "cd $REMOTE/webui && ../.venv/bin/python -m api.app_updates upload \
  --platform $platform --build $build --size $size --commit '$commit' --notes $(printf %q "$notes")" < "$file"
