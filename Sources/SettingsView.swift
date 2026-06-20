import SwiftUI

/// The Settings window content.
///
/// Two clearly partitioned cards — Syncthing (primary) above the app itself —
/// each leading with the most informational/actionable items (current version in
/// the header, then update status and its action) and placing set-and-forget
/// preferences below a divider.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var appSource: UpdateSource
    @ObservedObject var syncthingSource: UpdateSource

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Primary: the Syncthing daemon.
            SettingsCard(title: "Syncthing",
                         systemImage: "arrow.triangle.2.circlepath",
                         version: syncthingSource.currentVersion ?? "Not installed") {
                UpdateStatusRow(source: syncthingSource)

                Divider()

                Toggle("Automatically check for updates",
                       isOn: $settings.syncthingAutoCheckEnabled)
                Toggle("Install updates automatically",
                       isOn: $settings.syncthingAutoInstallEnabled)
                    .disabled(!settings.syncthingAutoCheckEnabled)   // slaved to auto-check
                Text("Major Syncthing updates always ask before installing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Secondary: this menu-bar app.
            SettingsCard(title: "Application",
                         systemImage: "menubar.rectangle",
                         version: appVersion) {
                UpdateStatusRow(source: appSource)

                Divider()

                Toggle("Automatically check for updates",
                       isOn: $settings.appAutoCheckEnabled)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// A titled card: SF Symbol + name on the left, current version right-aligned in
/// the header, and arbitrary content stacked below.
private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let version: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
                Text(version)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One update-status row: a state label (with icon) on the left, and the
/// contextual action button on the right. An available update is tinted and
/// gets a prominent button to draw the eye; everything else stays quiet.
private struct UpdateStatusRow: View {
    @ObservedObject var source: UpdateSource

    var body: some View {
        HStack(spacing: 8) {
            statusLabel
            Spacer()
            actionButton
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch source.state {
        case .unknown:
            Label("Not checked yet", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case let .available(version, isMajor):
            Label(isMajor ? "\(version) available · major update" : "\(version) available",
                  systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch source.state {
        case let .available(_, isMajor):
            Button(isMajor ? "Review & Install…" : "Update") {
                source.installAvailable()
            }
            .buttonStyle(.borderedProminent)
        case .installing:
            EmptyView()
        case .checking:
            Button("Check Now") {}.disabled(true)
        default:
            Button("Check Now") { source.checkNow() }
        }
    }
}
