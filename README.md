# Syncthing Menu

A frugal, native macOS menu-bar app for [Syncthing](https://syncthing.net).

It runs the Syncthing daemon as a background process and gives it a simple
menu-bar presence (status, open web UI, quit) — no Dock icon, no heavyweight UI.

> **Status:** early scaffold. The menu-bar shell builds and runs; the Syncthing
> supervisor and updater are stubs. Not yet signed or notarized.

## Why another wrapper?

The official `syncthing-macos` bundles the Syncthing binary **at build time** and
couples its version to the wrapper's, so every Syncthing release needs a new
wrapper release — which is why the bundled version drifts when the maintainer is
away.

Syncthing Menu is built around the opposite principle: **the daemon updates
independently of the app.** The wrapper rarely needs a new release.

## Design

- **Native Swift + AppKit.** `NSStatusItem` menu-bar agent (`LSUIElement`), no
  Dock icon. Minimal memory/idle footprint.
- **Binary fetched at runtime, not bundled.** The official, Apple-signed,
  universal Syncthing binary is downloaded from GitHub Releases into
  `~/Library/Application Support/`, with its SHA-256 verified — so no Go
  toolchain is ever needed here, and the daemon's Go version is whatever
  upstream shipped.
- **Two independent update channels:**
  - *Daemon:* either Syncthing's own signature-verified self-upgrader, or an
    app-managed poll-and-replace (decision still open — see below).
  - *App:* [Sparkle](https://sparkle-project.org), only for actual app changes.

## Project layout

```
Sources/                 Swift sources + asset catalog (file-system-synchronized group)
  main.swift             Explicit entry point (NSApplication setup)
  AppDelegate.swift      Lifecycle owner
  StatusItemController.swift  Menu-bar item + menu
  SyncthingProcess.swift Daemon supervisor (stub)
  ReleaseUpdater.swift   Binary download + checksum verify (stub)
Config/                  Info.plist + entitlements (referenced via build settings)
Scripts/                 sign-and-notarize.sh, make-dmg.sh (stubs)
.github/workflows/       ci.yml (unsigned build), release.yml (stub)
SyncthingMenu.xcodeproj  App target
```

## Building

Requires Xcode 16 or later.

```sh
# Open in Xcode and run, or build unsigned from the CLI:
xcodebuild -project SyncthingMenu.xcodeproj -target SyncthingMenu \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

To run a locally signed build from Xcode, set your team in the target's
**Signing & Capabilities** tab.

## Open decisions

- **Update ownership:** Syncthing self-upgrade vs. app-managed download — the
  next architectural decision (shapes `SyncthingProcess` / `ReleaseUpdater`).

## Distribution identity

Bundle identifier: `io.github.gtunes-dev.SyncthingMenu` (permanent — it's the
app's identity for preferences and the Sparkle update feed).

Signed with an **Individual** Apple Developer ID, so the code signature reads
`Developer ID Application: Greg Friedman (<TeamID>)`. The 10-character Team ID
may appear in project files once signing is configured in Xcode; that's expected
and not sensitive. The signing certificate and notarization credentials are
never committed (see `.gitignore`).

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Greg Friedman.
