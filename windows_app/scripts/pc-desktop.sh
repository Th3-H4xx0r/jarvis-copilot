#!/usr/bin/env bash
# Run a PowerShell command in Pranav's interactive desktop session (ssh sessions can't see the
# desktop): write it to ~/jc-dev/cmd.ps1, run the \Jarvis\Dev scheduled task, wait for __done__.
#   windows_app/scripts/pc-desktop.sh 'whoami; (Get-Process explorer).SessionId'
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 '<pwsh command>'" >&2; exit 2; }
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$1" > "$tmp"
ssh jc-pc 'pwsh -NoProfile -c "New-Item -ItemType Directory -Force $env:USERPROFILE\jc-dev | Out-Null; Remove-Item -Force -ErrorAction SilentlyContinue $env:USERPROFILE\jc-dev\out.txt; exit 0"'
scp -q "$tmp" jc-pc:jc-dev/cmd.ps1
ssh jc-pc 'schtasks /Run /TN \Jarvis\Dev' >/dev/null
for _ in $(seq 1 60); do
  out="$(ssh jc-pc 'pwsh -NoProfile -c "if (Test-Path $env:USERPROFILE\jc-dev\out.txt) { Get-Content -Raw $env:USERPROFILE\jc-dev\out.txt }"' || true)"
  if printf '%s' "$out" | grep -q '__done__'; then
    printf '%s\n' "$out" | grep -v '__done__'
    exit 0
  fi
  sleep 1
done
echo "pc-desktop: no __done__ within 60 s" >&2
exit 1
