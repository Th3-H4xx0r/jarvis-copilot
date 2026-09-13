#!/bin/bash
# Build the Mac voice dylib and install it where the Python client loads it.
#
#   ./build.sh              release (what ships)
#   ./build.sh debug        debug build, same install step
#
# Two products land in desktop_client/jc_client/assets/, and BOTH are needed:
#
#   libJarvisVoiceUI.dylib               the code, universal (arm64 + x86_64)
#   JarvisVoiceUI_JarvisVoiceUI.bundle   its resources, including the orb's
#                                        compiled shader - `Bundle.module`
#                                        looks for it beside the dylib
#
# Both are committed to the repo: `jc-client update` is a git sync plus a pip
# install and never compiles Swift, so whatever is committed here is what every
# client runs. Re-run this after touching anything under mac_app/ or the phone's
# Voice/Core sources, and commit the result.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
ASSETS="../desktop_client/jc_client/assets"
LIB="libJarvisVoiceUI.dylib"
BUNDLE_NAME="JarvisVoiceUI_JarvisVoiceUI.bundle"

# Universal on purpose. A dylib the running Mac cannot load is not an error the
# user ever sees - `mac_popover` catches it and quietly falls back to the web
# panel - so an arm64-only build would silently downgrade every Intel Mac.
# Built one arch at a time and lipo'd: `swift build --arch a --arch b` routes
# through xcodebuild, which insists on a separately downloadable Metal toolchain
# component even though `xcrun metal` below works fine.
SLICES=()
NATIVE_BIN=""
for arch in arm64 x86_64; do
    if swift build -c "$CONFIG" --arch "$arch"; then
        bin="$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)"
        SLICES+=("$bin/$LIB")
        [ "$arch" = "$(uname -m)" ] && NATIVE_BIN="$bin"
    else
        echo "build.sh: the $arch build failed - the dylib will not load on $arch Macs" >&2
    fi
done
[ ${#SLICES[@]} -gt 0 ] || { echo "build.sh: nothing built" >&2; exit 1; }
# The resource bundle is architecture-independent; take it from whichever slice
# we have (preferring this machine's, which is certainly present).
BUNDLE_SRC="${NATIVE_BIN:-$(dirname "${SLICES[0]}")}/$BUNDLE_NAME"
[ -d "$BUNDLE_SRC" ] || { echo "build.sh: no resource bundle at $BUNDLE_SRC" >&2; exit 1; }

mkdir -p "$ASSETS"
lipo -create "${SLICES[@]}" -output "$ASSETS/$LIB"

rm -rf "$ASSETS/$BUNDLE_NAME"
cp -R "$BUNDLE_SRC" "$ASSETS/$BUNDLE_NAME"

# The orb's shader. SwiftPM copies `.metal` files into the bundle but never runs
# the Metal compiler on them, so `ShaderLibrary` would find nothing at runtime
# and the orb would render as an empty rectangle - silently, since a missing
# shader function is not an error you can catch. Compiling it here is what makes
# `ShaderLibrary.bundle(...)` in `VoiceOrb.swift` resolve. Metal libraries are
# AIR bytecode, so one copy serves every architecture.
METAL="Sources/JarvisVoiceUI/Voice/Views/OrbShader.metal"
AIR="$(mktemp -t OrbShader).air"
trap 'rm -f "$AIR"' EXIT
xcrun -sdk macosx metal -c "$METAL" -o "$AIR"
xcrun -sdk macosx metallib "$AIR" -o "$ASSETS/$BUNDLE_NAME/default.metallib"
# The copied source is dead weight once the library is built beside it.
rm -f "$ASSETS/$BUNDLE_NAME/OrbShader.metal"

echo "build.sh: installed $CONFIG $(lipo -archs "$ASSETS/$LIB") dylib + bundle into $ASSETS"
