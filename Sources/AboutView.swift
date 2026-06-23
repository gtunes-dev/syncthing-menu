import SwiftUI
import AppKit

/// The About window content: the app's identity up top, the upstream Syncthing
/// attribution in the middle, then this app's license, project link, and
/// copyright — three regions separated by horizontal rules.
struct AboutView: View {
    /// The running Syncthing daemon version (already prefixed with "v"), or nil
    /// when the daemon isn't running.
    let syncthingVersion: String?

    private static let repoURL = URL(string: "https://github.com/gtunes-dev/syncthing-menu")!

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    private var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage(named: "AppMark") ?? NSImage()
    }

    /// The Syncthing version (if known) is folded into this line parenthetically.
    private var syncthingLine: String {
        let version = syncthingVersion.map { " (\($0))" } ?? ""
        return "Runs the official Syncthing app\(version) — © The Syncthing Authors, "
            + "licensed under the MPL-2.0. The Syncthing logo is © Kastelo AB."
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── App identity ──────────────────────────────────────────────────
            VStack(spacing: 10) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 76, height: 76)
                Text("Syncthing Menu")
                    .font(.title2.weight(.bold))
                Text("Version \(appVersion)")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 26)
            .padding(.bottom, 22)

            Divider()

            // ── Syncthing attribution (logo centered above the text) ──────────
            VStack(spacing: 12) {
                Image("SyncthingLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                Text(syncthingLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 24)

            Divider()

            // ── This app: license, project link, copyright ────────────────────
            VStack(spacing: 12) {
                Text("Syncthing Menu is open source under the MIT license.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Link(destination: Self.repoURL) {
                    Label("View on GitHub", systemImage: "arrow.up.forward.square")
                }
                .controlSize(.large)
                Text("© 2026 Greg Friedman")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 22)
        }
        .frame(width: 360)
    }
}
