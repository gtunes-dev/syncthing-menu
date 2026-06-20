#!/usr/bin/env bash
#
# make-dmg.sh — STUB (not yet functional)
#
# Packages the signed, notarized SyncthingMenu.app into a distributable .dmg
# with an /Applications symlink for drag-to-install.
#
# Planned approach: use `hdiutil` (or `create-dmg`) to build the disk image,
# then sign and staple the .dmg itself.
#
set -euo pipefail
echo "make-dmg.sh is a stub. Implement once the signed .app is produced." >&2
exit 1
