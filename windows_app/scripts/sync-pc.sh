#!/usr/bin/env bash
# Mirror the Mac working tree's windows_app/ (tracked + untracked, not ignored) onto the PC's
# build clone at ~/src/jarvis-copilot. The PC clone is a build mirror, never edited by hand.
# Files deleted here (tracked on origin/main, gone from this tree) are removed there too.
# The PC's ssh shell is Windows PowerShell 5.1: native tools don't expand `~`, so use $HOME.
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
mkdir -p windows_app/out
git ls-files -co --exclude-standard windows_app | sort > windows_app/out/sync-files.txt
# No AppleDouble ._ files: csc reads them as (binary) sources.
COPYFILE_DISABLE=1 tar --no-mac-metadata -cf windows_app/out/sync.tar -T windows_app/out/sync-files.txt
git ls-tree -r --name-only origin/main -- windows_app | sort | comm -23 - windows_app/out/sync-files.txt > windows_app/out/sync-deleted.txt
scp -q windows_app/out/sync.tar jc-pc:jc-sync.tar
scp -q windows_app/out/sync-deleted.txt jc-pc:jc-sync-deleted.txt
ssh jc-pc 'cd ~/src/jarvis-copilot; git checkout -q -- windows_app; git clean -fdq -e bin -e obj -e out windows_app; git pull -q --ff-only; tar -xf $HOME/jc-sync.tar; Get-Content $HOME/jc-sync-deleted.txt | Where-Object { $_ } | ForEach-Object { Remove-Item -Force -ErrorAction SilentlyContinue $_ }'
