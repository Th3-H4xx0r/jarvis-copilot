#!/usr/bin/env bash
# Mirror the Mac working tree's windows_app/ (tracked + untracked, not ignored) onto the PC's
# build clone at ~/src/jarvis-copilot. The PC clone is a build mirror, never edited by hand.
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
mkdir -p windows_app/out
git ls-files -co --exclude-standard windows_app | tar -cf windows_app/out/sync.tar -T -
scp -q windows_app/out/sync.tar jc-pc:jc-sync.tar
ssh jc-pc 'cd ~/src/jarvis-copilot; git checkout -q -- windows_app; git clean -fdq -e bin -e obj -e out windows_app; git pull -q --ff-only; tar -xf ~/jc-sync.tar'
