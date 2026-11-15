#!/usr/bin/env bash
# Sync windows_app/ to the PC, build JarvisWin.zip there, and copy it back to windows_app/out/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
"$here/sync-pc.sh"
ssh jc-pc 'cd ~/src/jarvis-copilot; pwsh -NoProfile -File windows_app/scripts/package.ps1'
mkdir -p "$root/windows_app/out"
scp -q jc-pc:src/jarvis-copilot/windows_app/out/JarvisWin.zip "$root/windows_app/out/"
echo "$root/windows_app/out/JarvisWin.zip"
