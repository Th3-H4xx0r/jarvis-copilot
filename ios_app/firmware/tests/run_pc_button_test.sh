#!/bin/bash
# Builds and runs the PC button host test (no board needed).
set -euo pipefail
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/pc_button_test"
c++ -std=c++17 -Wall -Wextra -Werror -I../JarvisEsp32 pc_button_test.cpp -o "$OUT"
"$OUT"
