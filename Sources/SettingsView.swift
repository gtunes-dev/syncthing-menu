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
    @ObservedObject var loginItem: LoginItemController

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Primary: the Syncthing daemon.
            SettingsCard(title: "Syncthing",
                         version: syncthingSource.currentVersion ?? "Not installed",
                         icon: { Image("SyncthingLogo").resizable().scaledToFit() }) {
                UpdateStatusRow(source: syncthingSource)

                Divider()

                Toggle("Automatically check for updates",
                       isOn: $settings.syncthingAutoCheckEnabled)
                Toggle("Install minor updates automatically",
                       isOn: $settings.syncthingAutoInstallEnabled)
                    .disabled(!settings.syncthingAutoCheckEnabled)   // slaved to auto-check
                Text("Major Syncthing updates require user approval")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()

                FullDiskAccessSection(binaryURL: ReleaseUpdater.installedBinaryURL)
            }

            // Secondary: this menu-bar app.
            SettingsCard(title: "Syncthing Menu",
                         version: appVersion,
                         icon: { Image("AppMark").resizable().scaledToFit() }) {
                UpdateStatusRow(source: appSource)

                Divider()

                Toggle("Automatically check for updates",
                       isOn: $settings.appAutoCheckEnabled)
                Toggle("Open at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// A titled card: icon + name on the left, current version right-aligned in the
/// header, and arbitrary content stacked below. The icon is caller-supplied so each
/// card can use the appropriate mark (the full-color Syncthing logo, or our
/// monochrome menu-bar mark) sized to a consistent 18×18.
private struct SettingsCard<Icon: View, Content: View>: View {
    let title: String
    let version: String
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header lives inside the card (common region) with a divider to its
            // content, so the title and its controls read as one group.
            HStack(spacing: 8) {
                icon()
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.headline)
                Spacer()
                Text(version)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
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
            Button("Check Now") {}.disabled(true).buttonStyle(.borderedProminent)
        default:
            Button("Check Now") { source.checkNow() }.buttonStyle(.borderedProminent)
        }
    }
}
