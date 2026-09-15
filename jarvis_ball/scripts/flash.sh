#!/usr/bin/env bash
# Build and flash the Jarvis Ball over USB.
#
#   scripts/flash.sh            back up (first time per ball), build, flash
#   scripts/flash.sh --monitor  …then open the serial monitor
#   scripts/flash.sh --force    flash even if the backup doesn't look like the supported board
#
# The first flash of each ball saves its whole 16 MB flash to
# ~/.jarvis_ball/backups/<mac>.bin — restore it with scripts/restore.sh.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
monitor=0
force=0
for arg in "$@"; do
    case "$arg" in
        --monitor) monitor=1 ;;
        --force) force=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

idf="${IDF_PATH:-$HOME/esp/esp-idf-v6.0.3}"
if ! command -v idf.py >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$idf/export.sh" >/dev/null
fi

port="${JARVIS_BALL_PORT:-$(ls /dev/cu.usbmodem* 2>/dev/null | head -1 || true)}"
if [ -z "$port" ]; then
    echo "No ball on USB. Plug it in (USB-C), switch it on, and if it still doesn't show up hold BOOT while plugging in." >&2
    exit 1
fi
echo "ball on $port"

# No early `exit` in awk: closing the pipe mid-output kills esptool and pipefail aborts the script.
mac="$(python -m esptool --chip esp32s3 --port "$port" read-mac 2>&1 | awk '!found && /^MAC:/{gsub(":","",$2); print $2; found=1}' || true)"
[ -n "$mac" ] || { echo "Couldn't read the ball's MAC over $port" >&2; exit 1; }
backups="$HOME/.jarvis_ball/backups"
backup="$backups/$mac.bin"
if [ ! -f "$backup" ]; then
    mkdir -p "$backups"
    echo "first flash of $mac: backing up the factory firmware (16 MB, a few minutes)…"
    python -m esptool --chip esp32s3 --port "$port" -b 921600 read-flash 0 0x1000000 "$backup.partial"
    mv "$backup.partial" "$backup"
    echo "saved $backup"
fi
if ! grep -a -q -E "sp-esp32-s3-1\.28-box|JarvisBall/" "$backup" && [ "$force" -eq 0 ]; then
    echo "The backup doesn't mention sp-esp32-s3-1.28-box: this may be the old revision (different mic/speaker/screen pins)." >&2
    echo "Re-run with --force to flash anyway; the firmware's boot-time hardware check will still refuse unsupported boards." >&2
    exit 1
fi

cd "$here"
# The orb frames come from the phone's Metal shader; render them once (macOS only).
[ -f "$here/build_host/orb/orb_frames.bin" ] || "$here/scripts/render_orb.sh"
idf.py build
idf.py -p "$port" flash
# The `orb` partition (partitions/jarvis_16m.csv, 0x3A0000) holds the pre-rendered orb:
# write it when the frames changed for this ball.
frames="$here/build_host/orb/orb_frames.bin"
stamp="$here/build_host/orb/.flashed-$mac"
sum="$(shasum "$frames" | awk '{print $1}')"
if [ "$(cat "$stamp" 2>/dev/null)" != "$sum" ]; then
    python -m esptool --chip esp32s3 --port "$port" -b 921600 write-flash 0x3A0000 "$frames"
    echo "$sum" > "$stamp"
fi
if [ "$monitor" -eq 1 ]; then
    idf.py -p "$port" monitor
fi
