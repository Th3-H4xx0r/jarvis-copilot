#!/bin/bash
# Build the Mac voice dylib and install it where the Python client loads it.
#
#   ./build.sh              release (what ships)
#   ./build.sh debug        debug build, same install step
#
# Two products land in desktop_client/jc_client/assets/, and BOTH are needed:
#
#   libJarvisVoiceUI.dylib               the code
#   JarvisVoiceUI_JarvisVoiceUI.bundle   its resources, including the orb's
#                                        compiled shader - `Bundle.module`
#                                        looks for it beside the dylib
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
ASSETS="../desktop_client/jc_client/assets"

swift build -c "$CONFIG"
BUILT="$(swift build -c "$CONFIG" --show-bin-path)"
DYLIB="$BUILT/libJarvisVoiceUI.dylib"
BUNDLE="$BUILT/JarvisVoiceUI_JarvisVoiceUI.bundle"
[ -f "$DYLIB" ] || { echo "build.sh: no dylib at $DYLIB" >&2; exit 1; }
[ -d "$BUNDLE" ] || { echo "build.sh: no resource bundle at $BUNDLE" >&2; exit 1; }

# The orb's shader. SwiftPM copies `.metal` files into the bundle but never runs
# the Metal compiler on them, so `ShaderLibrary` would find nothing at runtime
# and the orb would render as an empty rectangle - silently, since a missing
# shader function is not an error you can catch. Compiling it here is what makes
# `ShaderLibrary.bundle(.module)` in `VoiceOrb.swift` resolve.
METAL="Sources/JarvisVoiceUI/Voice/Views/OrbShader.metal"
AIR="$(mktemp -t OrbShader).air"
trap 'rm -f "$AIR"' EXIT
xcrun -sdk macosx metal -c "$METAL" -o "$AIR"
xcrun -sdk macosx metallib "$AIR" -o "$BUNDLE/default.metallib"
# The copied source is dead weight once the library is built beside it.
rm -f "$BUNDLE/OrbShader.metal"

mkdir -p "$ASSETS"
rm -rf "$ASSETS/JarvisVoiceUI_JarvisVoiceUI.bundle"
cp "$DYLIB" "$ASSETS/"
cp -R "$BUNDLE" "$ASSETS/"

echo "build.sh: installed $CONFIG dylib + bundle into $ASSETS"
