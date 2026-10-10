#!/bin/bash
# Builds and runs the Tuya LAN codec host test (no board needed).
# Needs mbedTLS 3.x headers — the same major version arduino-esp32 ships:
#   brew install mbedtls@3
set -euo pipefail
cd "$(dirname "$0")"
M="${MBEDTLS_PREFIX:-$(brew --prefix mbedtls@3 2>/dev/null || true)}"
if [[ -z "$M" || ! -f "$M/include/mbedtls/gcm.h" ]]; then
  echo "mbedTLS 3 not found. brew install mbedtls@3 (or set MBEDTLS_PREFIX)" >&2
  exit 1
fi
OUT="${TMPDIR:-/tmp}/tuya_codec_test"
c++ -std=c++17 -Wall -Wextra -Werror -I../JarvisEsp32 -I"$M/include" tuya_codec_test.cpp \
    -L"$M/lib" -lmbedcrypto -o "$OUT"
"$OUT"
