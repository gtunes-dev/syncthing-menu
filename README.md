# Syncthing Menu

A frugal, native macOS menu-bar app for [Syncthing](https://syncthing.net).

It runs Syncthing quietly in the background and gives it a simple menu-bar
presence — status at a glance, one click to the web UI, and a small Settings
window for updates. No Dock icon, no heavyweight UI.

<p align="center">
  <img src="docs/menu.png" alt="The Syncthing Menu menu-bar dropdown" width="240">
</p>

[![Latest release](https://img.shields.io/github/v/release/gtunes-dev/syncthing-menu?label=download)](https://github.com/gtunes-dev/syncthing-menu/releases/latest)

## Getting Started

1. Download the latest **`SyncthingMenu-<version>.zip`** from the
   [**Releases** page](https://github.com/gtunes-dev/syncthing-menu/releases/latest).
2. Unzip it (double-click in Finder) and drag **Syncthing Menu.app** into your
   **Applications** folder.
3. Launch it. The build is signed and notarized, so it opens without Gatekeeper
   warnings. The icon appears in the menu bar — there's no Dock icon.

On first launch it downloads the official Syncthing daemon and starts it in the
background. Allow the **Local Network** prompt so Syncthing can reach your other
devices; if you sync folders in protected locations (Desktop, Documents, …) you
may also be asked for **Full Disk Access** (see [Permissions](#permissions)).
From then on it keeps both Syncthing and itself up to date automatically.

Requires macOS 13 or later.

## Why another wrapper?

The official [`syncthing-macos`](https://github.com/syncthing/syncthing-macos)
bundles the Syncthing binary **at build time**, coupling the daemon's version to
the wrapper's. Every Syncthing release needs a new wrapper release, so the
bundled daemon drifts whenever the wrapper isn't updated in lockstep.

Syncthing Menu is built around the opposite principle: **the daemon updates
independently of the app.** It downloads the official Syncthing binary at runtime
and keeps it current on its own, so the menu-bar app itself rarely needs an
update.

## How it works

- **Native Swift + AppKit.** An `NSStatusItem` menu-bar agent (`LSUIElement`) —
  no Dock icon, minimal idle footprint.
- **Daemon fetched at runtime, not bundled.** On first launch the app downloads
  the official, Apple-signed, universal Syncthing binary from Syncthing's GitHub
  Releases into `~/Library/Application Support/Syncthing Menu/`. The download's
  SHA-256 is checked, and the binary's Apple Developer ID signature — Syncthing's
  own — is verified at installation and again before every launch. No Go
  toolchain is ever needed, and the daemon is exactly what upstream shipped.
- **The app owns daemon updates.** Syncthing's autonomous self-upgrade timer is
  disabled; instead the app checks for new releases and applies them on your
  terms (see **Updates** below). Minor updates can install automatically; major
  versions always ask first.
- **The app updates itself via [Sparkle](https://sparkle-project.org)** — only
  for actual changes to the menu-bar app, which are rare.
- **Or it manages nothing at all.** If you already run Syncthing yourself,
  Settings can point the app at your instance instead (see
  [Using your own Syncthing](#using-your-own-syncthing)).

## The menu

Click the menu-bar icon for:

- **Live status** — a colored dot and a one-line state: running, syncing,
  paused, starting, stopped, failed, or needing attention (a folder Syncthing
  can't access).
- **Open Syncthing** — Syncthing's full web interface in your browser.
- **Folders** — your sync folders; click one to open it in Finder.
- **Rescan All** and **Pause All Devices ⇄ Resume All Devices**.
- **Start Syncthing** — appears when the daemon is stopped or has failed.
- **Update … to X** — a direct install action per channel, appearing only while
  that update is pending.
- **Activity…** — a live, file-by-file view of what Syncthing is doing (below).
- **Settings…** — update preferences for both channels, Open at login, and Full
  Disk Access setup. Carries a caution badge when a folder needs attention.
- **About Syncthing Menu** — versions and release-notes links for both.
- **Quit** — stops the daemon it manages, then exits.

The menu-bar icon itself reflects state: a quiet monochrome mark when all is
well, distinct marks while syncing or paused, an alert mark when the daemon
can't run or a folder needs attention, and a badged variant when an update is
available. Its tooltip always carries the full one-line story.

## Activity

A live view of what Syncthing is doing, file by file: each change, which device
made it, and its progress from detected through delivered, applied, or failed.
Rows filter by change type and origin and sort by any column, and the window can
be pinned above others. Holding ⌥ over the menu item turns it into **Activity
(Reset Layout)…**. The window costs nothing while closed.

<p align="center">
  <img src="docs/activity.png" alt="The Syncthing Menu Activity window" width="760">
</p>

## Permissions

When the app manages Syncthing, it launches the daemon directly as a background
process, so on a couple of occasions macOS may ask you to grant it access. This
is expected.

### Local Network

The first time Syncthing tries to reach other devices, macOS shows a **Local
Network** prompt. Allow it — Syncthing needs local-network access to discover
and sync with your other machines.

### Full Disk Access (only sometimes)

macOS protects certain locations (Desktop, Documents, Pictures, Downloads, and
external/network volumes). If you sync a folder in one of those, Syncthing may
need **Full Disk Access**. Folders in ordinary locations need nothing.

Settings includes a **Set Up Full Disk Access…** helper that reveals the exact
file to grant and opens the right System Settings pane. One important detail: the
file to enable is the lowercase **`syncthing`** binary this app manages — if you
also run the standalone Syncthing app, that's a separate entry and granting it
won't help.

## Updates

Two independent update channels, surfaced as matching cards in Settings (the
Syncthing channel only while the app manages the daemon):

- **Syncthing (the daemon):** auto-check is on by default. Automatic install of
  *minor* updates is off by default (you can turn it on); *major* updates always
  ask first. After an update is applied, the app restarts the daemon so it comes
  back up cleanly.
- **Syncthing Menu (the app):** delivered through Sparkle; auto-check is on by
  default. Automatic install is off by default — with it on, updates download in
  the background and install silently, no dialogs.

Every version shown is a link to its release notes, and each card notes when it
last checked.

<p align="center">
  <img src="docs/settings.png" alt="The Syncthing Menu Settings window" width="440">
</p>

## Using your own Syncthing

Already running Syncthing yourself? In Settings, set **Syncthing is** →
**managed by me** and give it the port and API key of your local instance — the
key is in Syncthing's web interface under *Actions → Settings → General*. The
card reports the live connection state as you type.

The app is then purely an interface: menu, status, folders, and Activity work as
usual, but it never downloads, starts, stops, or updates Syncthing, and quitting
leaves your daemon running. Everything above describes the default, **managed by
this app**.

## Troubleshooting & reporting a problem

Syncthing Menu logs through the macOS unified logging system under the
subsystem `io.github.gtunes-dev.SyncthingMenu`. To watch events live, use
Console.app (filter by that subsystem) or:

```sh
log stream --predicate 'subsystem == "io.github.gtunes-dev.SyncthingMenu"'
```

To capture recent history for a bug report:

```sh
log show --last 2h --predicate 'subsystem == "io.github.gtunes-dev.SyncthingMenu"' > syncthing-menu.log
```

The daemon the app manages also keeps its own rotating log file, which survives
app restarts:

```
~/Library/Application Support/Syncthing Menu/home/syncthing.log
```

When [filing an issue](https://github.com/gtunes-dev/syncthing-menu/issues),
please attach both logs along with the app and Syncthing versions from the
About box. **Before posting, review both logs and redact anything you'd rather
not share** — the daemon log in particular can mention your folder names and
paths, device names and IDs, and local network addresses. Issues are public.

## Building

Requires Xcode 26 on a macOS 26 host. The project format itself needs only
Xcode 16, but the layered `AppIcon.icon` compiles only on macOS 26 — which is
what CI uses.

```sh
# Open in Xcode and run, or build unsigned from the CLI:
xcodebuild -project SyncthingMenu.xcodeproj -target SyncthingMenu \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

# Run the test suite:
Scripts/test.sh
```

To run a locally signed build from Xcode, set your team in the target's
**Signing & Capabilities** tab.

## Project layout

```
Sources/                 Swift sources, asset catalog, and the layered app icon
Tests/                   Unit + integration tests (Swift Testing; run with Scripts/test.sh)
Config/                  Info.plist + entitlements (referenced via build settings)
Scripts/                 test.sh, release + notarization, icon and dev helpers
design/                  Icon and logo design sources
docs/                    Screenshots used by this README
.github/workflows/       ci.yml (build + tests), release.yml, soak-build.yml
SyncthingMenu.xcodeproj  App + test targets
```

`Sources/` is a file-system-synchronized Xcode group: adding a file to the
directory adds it to the target, with no project edit needed. Each source file
opens with a comment explaining its role.

## Distribution identity

Bundle identifier: `io.github.gtunes-dev.SyncthingMenu` (permanent — it's the
app's identity for preferences and the Sparkle update feed).

Signed with an **Individual** Apple Developer ID, so the code signature reads
`Developer ID Application: Greg Friedman (<TeamID>)`. The 10-character Team ID
may appear in project files once signing is configured; that's expected and not
sensitive. Signing certificates and notarization credentials are never committed
(see `.gitignore`).

## Acknowledgments

[Syncthing](https://syncthing.net) is an independent project; this is an
unofficial wrapper and is not affiliated with or endorsed by it. Syncthing Menu
downloads and runs the official Syncthing binary unmodified.

The Syncthing logo used in this app is © The Syncthing Authors / Kastelo AB and
is licensed under the [Mozilla Public License 2.0](https://www.mozilla.org/MPL/2.0/).

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Greg Friedman.
