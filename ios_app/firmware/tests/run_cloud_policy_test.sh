#!/bin/bash
# Builds and runs the cloud-link policy host test (no board needed).
set -euo pipefail
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/cloud_policy_test"
c++ -std=c++17 -Wall -Wextra -Werror -I../JarvisEsp32 cloud_policy_test.cpp -o "$OUT"
"$OUT"
