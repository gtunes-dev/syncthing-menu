#!/usr/bin/env bash
#
# dev-pin-syncthing.sh <version>    e.g.  dev-pin-syncthing.sh v2.1.0
#
# DEV/TEST helper. Installs a specific (usually older) Syncthing universal binary
# into the app's managed bin path, to exercise the in-app upgrade flow:
#   1. pin an older version here,
#   2. launch the app — the daemon runs the older version (bootstrap skips download
#      because a binary is already present),
#   3. the Syncthing card's "Check Now" should report the newer version available,
#   4. "Update" (or auto-install) should upgrade it back to current.
#
# This downloads + SHA-256-verifies the binary the same way the app's bootstrap does.
set -euo pipefail

VER="${1:?usage: dev-pin-syncthing.sh <version, e.g. v2.1.0>}"
DEST="$HOME/Library/Application Support/Syncthing Menu/bin/syncthing"
BASE="https://github.com/syncthing/syncthing/releases/download/${VER}"
ASSET="syncthing-macos-universal-${VER}.zip"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "downloading ${ASSET}…"
curl -fsSL -o "$tmp/st.zip" "${BASE}/${ASSET}"
curl -fsSL -o "$tmp/sums"   "${BASE}/sha256sum.txt.asc"

expected="$(grep "  ${ASSET}\$" "$tmp/sums" | awk '{print $1}')"
actual="$(shasum -a 256 "$tmp/st.zip" | awk '{print $1}')"
if [ "$expected" != "$actual" ]; then
  echo "checksum mismatch for ${ASSET}" >&2
  exit 1
fi

ditto -x -k "$tmp/st.zip" "$tmp/x"
bin="$(find "$tmp/x" -name syncthing -type f | head -1)"
mkdir -p "$(dirname "$DEST")"
cp "$bin" "$DEST"
chmod +x "$DEST"

echo "pinned: $("$DEST" --version | head -1)"
echo "Quit and relaunch Syncthing Menu to run this version."
