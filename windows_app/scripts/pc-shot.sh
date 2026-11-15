#!/usr/bin/env bash
# Screenshot Pranav's whole PC desktop to windows_app/out/shots/<name>.png (gitignored).
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <name>" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
"$here/pc-desktop.sh" "Shot $1"
mkdir -p "$root/windows_app/out/shots"
scp -q "jc-pc:jc-dev/$1.png" "$root/windows_app/out/shots/"
echo "$root/windows_app/out/shots/$1.png"
