#!/usr/bin/env bash
# Install the pinned rclone the dashcam relay uses (webui/api/dashcam_relay.py).
#
#   scripts/install-rclone.sh            # -> /usr/local/bin/rclone
#   RCLONE_PREFIX=~/bin scripts/install-rclone.sh
#
# Downloads the official release zip, checks it against the sha256 pinned below
# (from https://downloads.rclone.org/<version>/SHA256SUMS), and installs the binary.
# Idempotent: does nothing when that exact version is already installed. Prints the
# installed version. To upgrade, bump VERSION and both hashes together.
set -euo pipefail

VERSION="v1.75.1"
SHA_LINUX_AMD64="982b5aa772841168f8e380f139e9e787b2a105403e32b94da8676a0e1c0a13ab"
SHA_LINUX_ARM64="03f2504174034b6d004152ed7369251c9a9ec1f7e0836eda420f5c7a5ec0dff9"
SHA_OSX_ARM64="c61d7a371c62bcbbe882c3423aa4b8bf63485c248dd0f692997b8f0c3f6d0c6f"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)          ASSET="rclone-${VERSION}-linux-amd64"; SHA="$SHA_LINUX_AMD64" ;;
  Linux-aarch64|Linux-arm64) ASSET="rclone-${VERSION}-linux-arm64"; SHA="$SHA_LINUX_ARM64" ;;
  Darwin-arm64)          ASSET="rclone-${VERSION}-osx-arm64"; SHA="$SHA_OSX_ARM64" ;;
  *) echo "install-rclone: no pinned build for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

PREFIX="${RCLONE_PREFIX:-/usr/local/bin}"
DEST="$PREFIX/rclone"

if [ -x "$DEST" ] && [ "$("$DEST" version 2>/dev/null | head -n 1)" = "rclone ${VERSION}" ]; then
  echo "rclone ${VERSION} is already installed at $DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://downloads.rclone.org/${VERSION}/${ASSET}.zip"
echo "Downloading $URL"
curl -fsSL --retry 3 -o "$TMP/rclone.zip" "$URL"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$TMP/rclone.zip" | awk '{print $1}')"
else
  ACTUAL="$(shasum -a 256 "$TMP/rclone.zip" | awk '{print $1}')"
fi
if [ "$ACTUAL" != "$SHA" ]; then
  echo "install-rclone: sha256 mismatch for ${ASSET}.zip (expected $SHA, got $ACTUAL)" >&2
  exit 1
fi

if command -v unzip >/dev/null 2>&1; then
  unzip -q "$TMP/rclone.zip" -d "$TMP/x"
else
  python3 -m zipfile -e "$TMP/rclone.zip" "$TMP/x"
fi

SUDO=""
if [ ! -d "$PREFIX" ]; then
  mkdir -p "$PREFIX" 2>/dev/null || SUDO="sudo"
  [ -z "$SUDO" ] || $SUDO mkdir -p "$PREFIX"
fi
if [ ! -w "$PREFIX" ]; then
  SUDO="sudo"
fi
$SUDO install -m 0755 "$TMP/x/${ASSET}/rclone" "$DEST"

"$DEST" version | head -n 1
