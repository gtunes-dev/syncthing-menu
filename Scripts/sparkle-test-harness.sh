#!/usr/bin/env bash
#
# sparkle-test-harness.sh — DEV TOOL (Phase A: local update testing)
#
# Builds the app at a bumped version, packages it as a Sparkle update, signs it
# with Sparkle's `generate_appcast` (EdDSA key from your Keychain), and serves the
# appcast + zip over http on loopback so Sparkle can actually fetch them. You then
# launch the CURRENT build pointed at that feed to watch the real
# check -> found -> badge -> Sparkle window flow — no hosting, no Developer ID.
#
# Why http and not file://: Sparkle fetches the appcast with URLSession, which does
# not support file:// URLs. Loopback http works (and is what the app already uses to
# talk to the Syncthing daemon). Sparkle permits insecure http because our updates
# are EdDSA-signed.
#
# Scope: validates fetch -> verify -> found -> badge -> window, and the download.
# The final in-place INSTALL/relaunch needs Developer ID (signature continuity +
# Gatekeeper) — that is Phase B.
#
# Usage:  Scripts/sparkle-test-harness.sh [version] [build] [port]
#         (defaults: 0.2.0  99  51234)   — Ctrl-C to stop the server when done.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
STAGE="$ROOT/build/sparkle-test"          # under build/ -> already gitignored
TEST_VERSION="${1:-0.2.0}"
TEST_BUILD="${2:-99}"
PORT="${3:-51234}"
BASE="http://127.0.0.1:$PORT"

GEN=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path "*artifacts/sparkle/Sparkle/bin/generate_appcast" 2>/dev/null | head -1)
if [ -z "${GEN:-}" ] || [ ! -x "$GEN" ]; then
  echo "error: generate_appcast not found. Resolve packages first:" >&2
  echo "  xcodebuild -project SyncthingMenu.xcodeproj -resolvePackageDependencies" >&2
  exit 1
fi

echo "==> Building SyncthingMenu $TEST_VERSION ($TEST_BUILD) as the 'update'…"
rm -rf "$STAGE"; mkdir -p "$STAGE"
xcodebuild -project SyncthingMenu.xcodeproj -scheme SyncthingMenu -configuration Debug \
  MARKETING_VERSION="$TEST_VERSION" CURRENT_PROJECT_VERSION="$TEST_BUILD" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  CONFIGURATION_BUILD_DIR="$STAGE/app" build >/dev/null

echo "==> Packaging update zip…"
( cd "$STAGE/app" && ditto -c -k --sequesterRsrc --keepParent \
    SyncthingMenu.app "$STAGE/SyncthingMenu-$TEST_VERSION.zip" )
rm -rf "$STAGE/app"

echo "==> Generating signed appcast (may prompt for Keychain access to the EdDSA key)…"
"$GEN" --download-url-prefix "$BASE/" "$STAGE"

FEED="$BASE/appcast.xml"
cat <<EOF

────────────────────────────────────────────────────────────────────────────
Signed appcast ready. Serving $STAGE at $BASE
(Leave this running. Ctrl-C to stop.)

In ANOTHER terminal, launch the CURRENT build pointed at the feed:

  SPARKLE_TEST_FEED_URL="$FEED" \\
    "$ROOT/build/Debug/SyncthingMenu.app/Contents/MacOS/SyncthingMenu"

Expect: the launch check finds $TEST_VERSION -> menu-bar icon shows the update
badge; "Check for Updates" shows Sparkle's window; it can download. The final
install/relaunch is Phase B (needs Developer ID). Logs print "[Sparkle] using
feed URL: …" so you can confirm the env var took effect.
────────────────────────────────────────────────────────────────────────────

EOF

exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$STAGE"
