#!/usr/bin/env bash
#
# sign-and-notarize.sh — STUB (not yet functional)
#
# Signs the built .app with a Developer ID Application certificate, enables the
# hardened runtime, submits it to Apple's notary service, and staples the ticket.
#
# Prerequisites (to be wired up once a Developer ID is available):
#   - Developer ID Application certificate imported into the keychain
#   - Notarization credentials (App Store Connect API key: Issuer ID, Key ID, .p8)
#   - All of the above provided via environment / CI secrets, never committed
#
# Planned steps:
#   1. codesign --force --options runtime --entitlements Config/SyncthingMenu.entitlements \
#        --sign "Developer ID Application: ..." "$APP_PATH"
#   2. Zip the .app and submit with: xcrun notarytool submit ... --wait
#   3. xcrun stapler staple "$APP_PATH"
#
set -euo pipefail
echo "sign-and-notarize.sh is a stub. Implement once a Developer ID is configured." >&2
exit 1
