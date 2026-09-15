#!/usr/bin/env bash
# Put a pod's factory firmware back: scripts/restore.sh ~/.jarvis_pod/backups/<mac>.bin
set -euo pipefail
backup="${1:?usage: restore.sh <backup.bin>}"
[ -f "$backup" ] || { echo "no such file: $backup" >&2; exit 1; }
idf="${IDF_PATH:-$HOME/esp/esp-idf-v6.0.3}"
command -v idf.py >/dev/null 2>&1 || . "$idf/export.sh" >/dev/null
port="${JARVIS_POD_PORT:-$(ls /dev/cu.usbmodem* 2>/dev/null | head -1 || true)}"
[ -n "$port" ] || { echo "No pod on USB" >&2; exit 1; }
python -m esptool --chip esp32s3 --port "$port" -b 921600 write-flash 0 "$backup"
echo "restored $backup to the pod on $port"
