#!/bin/bash
# Builds FreeRDP (pinned in VERSION) + OpenSSL for iOS device (arm64) and the arm64 simulator,
# with every client channel built in (cliprdr, rdpsnd/ios, rdpdr+drive, drdynvc, disp, rdpgfx),
# adds Jarvis's small C shim (shim/jarvis_rdp.c — the only API Swift sees, through
# shim/module.modulemap), merges each platform into one static library and packages
#   FreeRDP.xcframework   (ios-arm64, ios-arm64-simulator; Headers = jarvis_rdp.h + module map)
#
# The artefact (~60 MB) is cached outside git, in $JARVIS_FREERDP_CACHE (default
# ~/Library/Caches/jarvis-freerdp/<FREERDP_TAG>-<short sha>/), and linked into the repo as
#   ios_app/vendor/freerdp/FreeRDP.xcframework  (symlink, git-ignored)
# The app builds without it (Remote Desktop then says it isn't in this build).
#
#   ios_app/vendor/freerdp/build-xcframework.sh            # everything (resumes finished stages)
#   ios_app/vendor/freerdp/build-xcframework.sh deps       # only OpenSSL + FreeRDP
#   ios_app/vendor/freerdp/build-xcframework.sh shim       # just re-compile the shim + repackage
#   ios_app/vendor/freerdp/build-xcframework.sh clean      # forget the cached build
#
# Needs: Xcode, cmake ≥ 3.13, ninja, perl, git. Reproducible: exact commits, fixed flags.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(grep -E '^[A-Z_]+=[A-Za-z0-9._-]+$' "$HERE/VERSION")"
SHORT="${FREERDP_SHA:0:8}"
CACHE="${JARVIS_FREERDP_CACHE:-$HOME/Library/Caches/jarvis-freerdp}"
SRC="$CACHE/src"
OUT="$CACHE/$FREERDP_TAG-$SHORT"
PLATFORMS=(OS64 SIMULATORARM64)
JOBS="$(sysctl -n hw.ncpu)"
STAGE="${1:-all}"

log() { printf '\n== %s\n' "$*"; }

if [ "$STAGE" = clean ]; then rm -rf "$OUT" "$HERE/FreeRDP.xcframework"; exit 0; fi

fetch() {  # name url tag sha
  local dir="$SRC/$1"
  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$SRC"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$3" "$2" "$dir"
  fi
  local head; head="$(git -C "$dir" rev-parse HEAD)"
  [ "$head" = "$4" ] || { echo "$1 is at $head, VERSION pins $4 — refusing" >&2; exit 1; }
}

sdk_of() { [ "$1" = OS64 ] && echo iphoneos || echo iphonesimulator; }
triple_of() { [ "$1" = OS64 ] && echo "arm64-apple-ios$DEPLOYMENT_TARGET" || echo "arm64-apple-ios$DEPLOYMENT_TARGET-simulator"; }

build_openssl() {  # platform
  local p="$1" prefix="$OUT/$1/deps" work="$OUT/$1/openssl"
  [ -f "$prefix/lib/libssl.a" ] && return 0
  log "OpenSSL $OPENSSL_TAG for $p"
  rm -rf "$work"; mkdir -p "$OUT/$p"; cp -R "$SRC/openssl" "$work"
  local target min
  target=$([ "$p" = OS64 ] && echo ios64-xcrun || echo iossimulator-arm64-xcrun)
  min=$([ "$p" = OS64 ] && echo "-mios-version-min=$DEPLOYMENT_TARGET" || echo "-mios-simulator-version-min=$DEPLOYMENT_TARGET")
  (cd "$work" &&
    CFLAGS="$min" ./Configure "$target" no-shared no-tests no-apps no-docs \
      no-engine no-dso --prefix="$prefix" --libdir=lib >/dev/null &&
    make -j"$JOBS" build_sw >/dev/null &&
    make install_sw >/dev/null)
}

build_freerdp() {  # platform
  local p="$1" prefix="$OUT/$1/deps" work="$OUT/$1/freerdp"
  [ -f "$prefix/lib/libfreerdp3.a" ] && return 0
  log "FreeRDP $FREERDP_TAG for $p"
  cmake -G Ninja -S "$SRC/FreeRDP" -B "$work" \
    -DCMAKE_TOOLCHAIN_FILE="$SRC/FreeRDP/cmake/ios.toolchain.cmake" \
    -DPLATFORM="$p" -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" -DENABLE_BITCODE=OFF \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix" \
    -DCMAKE_FIND_ROOT_PATH="$prefix" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DWITH_SAMPLE=OFF -DWITH_SERVER=OFF -DWITH_CLIENT=OFF \
    -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT_CHANNELS=ON -DWITH_CHANNELS=ON -DWITH_CLIENT_SDL=OFF \
    -DWITH_MANPAGES=OFF -DWITH_SYSTEMD=OFF -DWITH_PROXY=OFF -DWITH_SHADOW=OFF -DWITH_PLATFORM_SERVER=OFF \
    -DWITHOUT_FREERDP_3x_DEPRECATED=ON -DWITHOUT_WINPR_3x_DEPRECATED=ON \
    -DWITH_OPENSSL=ON -DOPENSSL_ROOT_DIR="$prefix" -DOPENSSL_USE_STATIC_LIBS=ON \
    -DWITH_INTERNAL_RC4=ON -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON \
    -DWITH_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF \
    -DWITH_VIDEOTOOLBOX=OFF -DWITH_CAIRO=OFF -DWITH_JPEG=OFF -DWITH_OPUS=OFF -DWITH_FAAD2=OFF -DWITH_FAAC=OFF \
    -DWITH_SOXR=OFF -DWITH_LAME=OFF -DWITH_URIPARSER=OFF -DWITH_JSON_DISABLED=ON -DWITH_AAD=OFF \
    -DWITH_KRB5=OFF -DWITH_PCSC=OFF -DWITH_SMARTCARD_EMULATE=OFF -DWITH_FUSE=OFF -DWITH_CUPS=OFF \
    -DWITH_PKCS11=OFF -DWITH_WEBVIEW=OFF -DWITH_SIMD=ON -DWITH_IOSAUDIO=ON -DWITH_MACAUDIO=OFF \
    -DCHANNEL_URBDRC=OFF -DCHANNEL_TSMF=OFF -DCHANNEL_AUDIN=OFF -DCHANNEL_RDPECAM=OFF -DCHANNEL_SMARTCARD=OFF \
    -DCHANNEL_PRINTER=OFF -DCHANNEL_SERIAL=OFF -DCHANNEL_PARALLEL=OFF -DCHANNEL_VIDEO=OFF -DCHANNEL_LOCATION=OFF \
    -DWINPR_UTILS_IMAGE_PNG=OFF -DWINPR_UTILS_IMAGE_WEBP=OFF -DWINPR_UTILS_IMAGE_JPEG=OFF >"$OUT/$p-cmake.log"
  cmake --build "$work" -j "$JOBS" >"$OUT/$p-build.log"
  cmake --install "$work" >/dev/null
}

build_shim() {  # platform
  local p="$1" prefix="$OUT/$1/deps" sdk; sdk="$(sdk_of "$p")"
  log "shim for $p"
  mkdir -p "$OUT/$p/shim"
  xcrun --sdk "$sdk" clang -c -O2 -fPIC -target "$(triple_of "$p")" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -I"$prefix/include/freerdp3" -I"$prefix/include/winpr3" -I"$HERE/shim" \
    -Wall -Werror=implicit-function-declaration "$HERE/shim/jarvis_rdp.c" -o "$OUT/$p/shim/jarvis_rdp.o"
  # One static library per platform: the shim, every FreeRDP/WinPR/channel archive, OpenSSL.
  local libs=("$OUT/$p/shim/jarvis_rdp.o")
  while IFS= read -r a; do libs+=("$a"); done < <(find "$prefix/lib" -name '*.a' | sort)
  mkdir -p "$OUT/$p/lib"
  xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/$p/lib/libFreeRDP.a" "${libs[@]}"
}

package() {
  log "FreeRDP.xcframework"
  local headers="$OUT/Headers"
  rm -rf "$headers" "$OUT/FreeRDP.xcframework"
  mkdir -p "$headers"
  cp "$HERE/shim/jarvis_rdp.h" "$HERE/shim/module.modulemap" "$headers/"
  local args=()
  for p in "${PLATFORMS[@]}"; do args+=(-library "$OUT/$p/lib/libFreeRDP.a" -headers "$headers"); done
  xcodebuild -create-xcframework "${args[@]}" -output "$OUT/FreeRDP.xcframework" >/dev/null
  ln -sfn "$OUT/FreeRDP.xcframework" "$HERE/FreeRDP.xcframework"
  du -sh "$OUT/FreeRDP.xcframework"
}

fetch FreeRDP https://github.com/FreeRDP/FreeRDP.git "$FREERDP_TAG" "$FREERDP_SHA"
fetch openssl https://github.com/openssl/openssl.git "$OPENSSL_TAG" "$OPENSSL_SHA"
mkdir -p "$OUT"
for p in "${PLATFORMS[@]}"; do
  if [ "$STAGE" != shim ]; then build_openssl "$p"; build_freerdp "$p"; fi
  [ "$STAGE" = deps ] || build_shim "$p"
done
[ "$STAGE" = deps ] && exit 0
package
echo "FreeRDP $FREERDP_TAG ($SHORT) → $HERE/FreeRDP.xcframework"
