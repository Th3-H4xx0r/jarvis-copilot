#!/usr/bin/env bash
# Render the phone's orb shader into build_host/orb/orb_frames.bin for the ball's `orb` partition.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"
out="$here/build_host/orb"
mkdir -p "$out"
swiftc -O -o "$out/render_orb" "$here/tools/orb_render/render_orb.swift"
"$out/render_orb" "$repo/ios_app/JarvisCopilot/Copilot/Voice/Views/OrbShader.metal" \
    "$out/orb_frames.bin" "$out/preview.png" 64 160 130
