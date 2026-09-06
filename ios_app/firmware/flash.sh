#!/bin/bash
# Compile the Jarvis ESP32 firmware and flash it to a DOIT ESP32 DEVKIT V1.
#
#   ./firmware/flash.sh              compile + upload to the first usbserial port
#   ./firmware/flash.sh --verify     compile only
#   ./firmware/flash.sh --monitor    compile, upload, then open the serial console
#   PORT=/dev/cu.usbserial-XXXX ./firmware/flash.sh
#
# Uses the arduino-cli bundled with Arduino IDE and the esp32 core already installed
# under ~/Library/Arduino15, so nothing extra has to be installed.
set -euo pipefail
cd "$(dirname "$0")"

SKETCH="JarvisEsp32"
# The DOIT DEVKIT V1 is a plain WROOM-32 module, so it builds as the generic "ESP32 Dev
# Module". That board definition (unlike the DOIT one) exposes the partition menu, and
# BLE + Wi‑Fi together need the 3 MB "Huge APP" slot — the default 1.3 MB is too small.
FQBN="esp32:esp32:esp32:PartitionScheme=huge_app,UploadSpeed=921600"
BUILD_DIR="$(pwd)/build"

CLI="${ARDUINO_CLI:-}"
if [[ -z "$CLI" ]]; then
  if command -v arduino-cli >/dev/null 2>&1; then
    CLI="arduino-cli"
  else
    CLI="/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli"
  fi
fi
if [[ ! -x "$CLI" ]] && ! command -v "$CLI" >/dev/null 2>&1; then
  echo "arduino-cli not found. Install Arduino IDE or set ARDUINO_CLI=/path/to/arduino-cli" >&2
  exit 1
fi

if ! "$CLI" core list 2>/dev/null | grep -q '^esp32:esp32'; then
  echo "esp32 core is not installed. In Arduino IDE: Boards Manager → 'esp32' by Espressif, or:" >&2
  echo "  $CLI core install esp32:esp32" >&2
  exit 1
fi

# Third-party library the sketch needs (JSON for the Jarvis bridge). Idempotent.
if ! "$CLI" lib list 2>/dev/null | grep -q '^ArduinoJson'; then
  echo "==> Installing ArduinoJson"
  "$CLI" lib install ArduinoJson
fi

MODE="${1:-upload}"

echo "==> Compiling $SKETCH for DOIT ESP32 DEVKIT V1 (huge_app partition)"
"$CLI" compile --fqbn "$FQBN" --build-path "$BUILD_DIR" --warnings default "$SKETCH"

if [[ "$MODE" == "--verify" ]]; then
  echo "==> Compile OK (verify only)"
  exit 0
fi

PORT="${PORT:-$(ls /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART /dev/cu.wchusbserial* 2>/dev/null | head -1 || true)}"
if [[ -z "$PORT" ]]; then
  echo "No USB serial port found. Plug the board in, or set PORT=/dev/cu.…" >&2
  exit 1
fi

echo "==> Uploading via $PORT"
echo "    (if this hangs at 'Connecting...', hold the BOOT button on the board until it starts writing)"
"$CLI" upload --fqbn "$FQBN" --port "$PORT" --input-dir "$BUILD_DIR" "$SKETCH"
echo "==> Flashed. The onboard LED should start blinking once a second while it advertises."

if [[ "$MODE" == "--monitor" ]]; then
  echo "==> Serial monitor (Ctrl-C to quit)"
  "$CLI" monitor --port "$PORT" --config baudrate=115200
fi
