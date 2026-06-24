#!/usr/bin/env bash
#
# sign-and-notarize.sh — build, Developer ID sign, notarize, and staple the app,
# producing the distributable .zip the release uses.
#
# Release model: a single .zip of the notarized+stapled Syncthing Menu.app is the
# GitHub Release asset. It does double duty — the human first-install download
# (unzip, drag to /Applications) AND Sparkle's auto-update enclosure. No DMG, no
# bare .app. (A DMG is optional first-install polish we may add later; it would
# just swap the packaging step.)
#
# Signing uses Xcode's archive -> export pipeline (NOT `codesign --deep`) so
# Sparkle's nested helpers (XPC services, Autoupdate.app, Updater.app) are signed
# in the correct order with the hardened runtime — the only flow Apple supports
# for an app that embeds Sparkle. Manual Developer ID signing needs no
# provisioning profile and ports to CI unchanged (import the .p12 into a temp
# keychain first).
#
# ── Modes ─────────────────────────────────────────────────────────────────────
#   SKIP_NOTARIZE=1   build + sign + verify the signature, then STOP. No Apple
#                     round-trip, no credentials needed. Fast gate for the most
#                     failure-prone part (Developer ID + Sparkle nested signing).
#
# ── Required credentials for a full run (never committed; pass via environment) ─
#   Provide EITHER a stored notarytool profile:
#       NOTARY_PROFILE   name of a profile saved with `notarytool store-credentials`
#   …OR the App Store Connect API key directly (this is what CI does):
#       NOTARY_KEY       path to the AuthKey_XXXXXXXXXX.p8 file
#       NOTARY_KEY_ID    the 10-char Key ID
#       NOTARY_ISSUER    the Issuer ID (UUID)
#
# ── Optional overrides ────────────────────────────────────────────────────────
#   TEAM_ID          Apple Developer Team ID    (default: HEHTBANX3P)
#   SIGN_IDENTITY    code-signing identity      (default: "Developer ID Application")
#   CONFIGURATION    xcodebuild configuration   (default: Release)
#   BUILD_DIR        output directory           (default: build)
#   RELEASE_VERSION  CFBundleShortVersionString (default: project's MARKETING_VERSION)
#   BUILD_NUMBER     CFBundleVersion            (default: project's CURRENT_PROJECT_VERSION)
#                    CI sets both from the git tag so each release is uniquely
#                    versioned — Sparkle compares CFBundleVersion to find "newer".
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   SKIP_NOTARIZE=1 ./Scripts/sign-and-notarize.sh           # signing smoke test
#   NOTARY_PROFILE=syncthing-menu ./Scripts/sign-and-notarize.sh   # full run
#
set -euo pipefail

# ── Locate the repo root (this script lives in Scripts/) ──────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

# ── Configuration ─────────────────────────────────────────────────────────────
PROJECT="SyncthingMenu.xcodeproj"
SCHEME="SyncthingMenu"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-HEHTBANX3P}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
BUILD_DIR="${BUILD_DIR:-build}"

ARCHIVE_PATH="$BUILD_DIR/SyncthingMenu.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/Syncthing Menu.app"

# Optional version overrides (CI passes these from the git tag). Unset → the
# project's own MARKETING_VERSION / CURRENT_PROJECT_VERSION are used.
VERSION_ARGS=()
[[ -n "${RELEASE_VERSION:-}" ]] && VERSION_ARGS+=("MARKETING_VERSION=$RELEASE_VERSION")
[[ -n "${BUILD_NUMBER:-}" ]] && VERSION_ARGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── Resolve notarization credentials (skipped for SKIP_NOTARIZE) ──────────────
NOTARY_ARGS=()
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    elif [[ -n "${NOTARY_KEY:-}" || -n "${NOTARY_KEY_ID:-}" || -n "${NOTARY_ISSUER:-}" ]]; then
        : "${NOTARY_KEY:?NOTARY_KEY (path to .p8) is required when not using NOTARY_PROFILE}"
        : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required when not using NOTARY_PROFILE}"
        : "${NOTARY_ISSUER:?NOTARY_ISSUER is required when not using NOTARY_PROFILE}"
        [[ -f "$NOTARY_KEY" ]] || die "NOTARY_KEY file not found: $NOTARY_KEY"
        NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    else
        die "No notarization credentials. Set NOTARY_PROFILE, or NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER (or pass SKIP_NOTARIZE=1)."
    fi
fi

# Fail early if the signing identity isn't in the keychain.
security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" \
    || die "No '$SIGN_IDENTITY' identity found in the keychain (run: security find-identity -v -p codesigning)."

# ── 1. Archive ────────────────────────────────────────────────────────────────
log "Archiving $SCHEME ($CONFIGURATION)…"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"}

# ── 2. Export with a Developer ID profile ─────────────────────────────────────
# exportArchive re-signs the app and every nested helper with the Developer ID
# identity, the hardened runtime, and a secure timestamp.
log "Exporting Developer ID build…"
EXPORT_PLIST="$(mktemp -t exportoptions).plist"
trap 'rm -f "$EXPORT_PLIST"' EXIT
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>            <string>developer-id</string>
    <key>teamID</key>            <string>$TEAM_ID</string>
    <key>signingStyle</key>      <string>manual</string>
    <key>signingCertificate</key><string>$SIGN_IDENTITY</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$EXPORT_DIR"

[[ -d "$APP_PATH" ]] || die "Export did not produce $APP_PATH"

# ── 3. Verify the signature before sending it to Apple ────────────────────────
log "Verifying code signature…"
codesign --verify --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=4 "$APP_PATH" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime" \
    || die "Signature is missing the Developer ID authority or hardened-runtime flag."

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
log "Signed Syncthing Menu.app (version $VERSION) — signature OK."

if [[ -n "${SKIP_NOTARIZE:-}" ]]; then
    log "SKIP_NOTARIZE set — stopping after signing (no notarization, no .zip)."
    exit 0
fi

# ── 4. Notarize (zip the .app, submit, wait for the verdict) ──────────────────
log "Submitting to the notary service (this can take a few minutes)…"
SUBMIT_ZIP="$BUILD_DIR/SyncthingMenu-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"
xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_ARGS[@]}" --wait \
    || die "Notarization failed. Inspect with: xcrun notarytool log <submission-id> ${NOTARY_ARGS[*]}"
rm -f "$SUBMIT_ZIP"

# ── 5. Staple and do a final Gatekeeper check ─────────────────────────────────
log "Stapling the notarization ticket…"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type exec --verbose=4 "$APP_PATH"

# ── 6. Package the distributable .zip (contains the stapled app) ──────────────
DIST_ZIP="$BUILD_DIR/SyncthingMenu-$VERSION.zip"
rm -f "$DIST_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$DIST_ZIP"

log "Done. Release artifact: $DIST_ZIP"
