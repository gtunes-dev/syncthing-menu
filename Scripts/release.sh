#!/usr/bin/env bash
#
# release.sh — cut a release.
#
# Validates the repo state, bumps MARKETING_VERSION to match, creates an
# annotated tag v<version>, and pushes main + the tag. Pushing the tag triggers
# .github/workflows/release.yml (build → Developer ID sign → notarize → staple →
# GitHub Release + Sparkle appcast on gh-pages).
#
# Usage:  Scripts/release.sh <version>        e.g.  Scripts/release.sh 0.1.0
#         (version is semver X.Y.Z, no leading "v")
#
set -euo pipefail

cd "$(dirname "$0")/.."
PROJ="SyncthingMenu.xcodeproj/project.pbxproj"
REMOTE_WEB="https://github.com/gtunes-dev/syncthing-menu"

die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
log() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }

# Return 0 iff $1 is a strictly higher X.Y.Z than $2 (portable; no `sort -V`).
version_gt() {
    [ "$1" = "$2" ] && return 1
    local IFS=. a b i x y
    a=($1); b=($2)
    for i in 0 1 2; do
        x=${a[i]:-0}; y=${b[i]:-0}
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 1
}

VERSION="${1:-}"
[ -n "$VERSION" ] || die "usage: Scripts/release.sh <version>   (e.g. 0.1.0)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be semver X.Y.Z (got: $VERSION)"
TAG="v$VERSION"

# ── Preconditions ─────────────────────────────────────────────────────────────
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || die "not on main (on '$BRANCH')"
git diff --quiet && git diff --cached --quiet || die "working tree has uncommitted changes — commit or stash first"

log "Fetching origin…"
git fetch origin --tags --quiet
[ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ] || die "local main is out of sync with origin/main — pull/push first"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"

LATEST="$(git tag --list 'v*' --sort=-v:refname | head -1)"
if [ -n "$LATEST" ]; then
    version_gt "$VERSION" "${LATEST#v}" || die "version $VERSION must be greater than the latest release $LATEST"
fi

# ── Bump version (commit only if it actually changes) ─────────────────────────
log "Setting MARKETING_VERSION = $VERSION…"
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g" "$PROJ"
git add "$PROJ"
if git diff --cached --quiet; then
    log "MARKETING_VERSION already $VERSION — no bump commit needed."
else
    git commit -q -m "Release $TAG"
fi

# ── Tag + push (this triggers the Release workflow) ───────────────────────────
log "Creating annotated tag $TAG and pushing…"
git tag -a "$TAG" -m "Release $TAG"
git push origin main
git push origin "$TAG"

log "Done — the Release workflow is now building $TAG."
echo "   Watch: $REMOTE_WEB/actions"
