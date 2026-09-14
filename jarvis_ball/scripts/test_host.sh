#!/usr/bin/env bash
# Build and run the ESP-IDF-free logic tests on the Mac.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/build_host"
mkdir -p "$out"

cjson_dir=""
for d in "$here"/managed_components/espressif__cjson/cJSON "${IDF_PATH:-/nonexistent}/components/json/cJSON"; do
    if [ -f "$d/cJSON.c" ]; then cjson_dir="$d"; break; fi
done
if [ -z "$cjson_dir" ]; then
    cjson_dir="$out/cJSON"
    if [ ! -f "$cjson_dir/cJSON.c" ]; then
        mkdir -p "$cjson_dir"
        curl -fsSL -o "$cjson_dir/cJSON.c" https://raw.githubusercontent.com/DaveGamble/cJSON/v1.7.18/cJSON.c
        curl -fsSL -o "$cjson_dir/cJSON.h" https://raw.githubusercontent.com/DaveGamble/cJSON/v1.7.18/cJSON.h
    fi
fi

cc -c -O1 -I"$cjson_dir" "$cjson_dir/cJSON.c" -o "$out/cJSON.o"
c++ -std=c++20 -O1 -Wall -Wextra -I"$cjson_dir" -I"$here/main/jarvis/logic" \
    "$here/main/jarvis/logic/jarvis_logic.cc" "$here/host_tests/test_logic.cc" "$out/cJSON.o" -o "$out/test_logic"
"$out/test_logic"
