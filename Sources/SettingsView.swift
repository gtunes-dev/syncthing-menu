import SwiftUI

/// The Settings window content: two symmetric cards — Syncthing Menu (this app) above
/// the Syncthing daemon it manages. Each card leads with the current version (a link
/// to its release notes), then update status and its action, then the channel's
/// preferences. The two channels share one `UpdateControls` body, so they look and
/// behave identically apart from each card's tail (Open at login / Full Disk Access).
struct SettingsView: View {
    @ObservedObject var appSource: UpdateSource
    @ObservedObject var syncthingSource: UpdateSource
    @ObservedObject var appSettings: UpdateChannelSettings
    @ObservedObject var syncthingSettings: UpdateChannelSettings
    @ObservedObject var daemonSettings: DaemonModeSettings
    @ObservedObject var activitySettings: ActivitySettings
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var folderHealth: FolderHealth
    @ObservedObject var status: SyncthingStatusModel

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    /// The Syncthing card's header version. Managed: the update channel owns it
    /// ("Not installed" until the first bootstrap). Self-managed: the connected
    /// daemon's reported version; a plain dash while disconnected — "Not
    /// installed" would be presumptuous about software we don't manage.
    private var syncthingVersion: String? {
        switch daemonSettings.mode {
        case .managed: syncthingSource.currentVersion
        case .selfManaged: status.selfManagedDaemonVersion
        }
    }

    /// The FDA section's alert message, when folders are blocked on permissions.
    private var fdaAttention: String? {
        let folders = folderHealth.permissionErrorFolders
        guard !folders.isEmpty else { return nil }
        let list = folders.map { "“\($0)”" }.joined(separator: ", ")
        return "Syncthing can't access \(folders.count == 1 ? "the folder" : "these folders"): "
            + "\(list). This usually means it needs Full Disk Access."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Syncthing Menu",
                         version: appVersion,
                         versionURL: appSource.releaseNotesURL(for: appVersion),
                         icon: { AppIconImage.view(points: 18) }) {
                UpdateControls(source: appSource, settings: appSettings)

                Divider()

                // Sentence-form row, like "Syncthing is …" below: the shared
                // subject lives in the label, so the two options differ only
                // in WHEN. The default is the option worth naming — a
                // checkbox would leave it implicit.
                Picker(selection: $activitySettings.recording) {
                    Text("while the Activity window is open")
                        .tag(ActivityRecordingPolicy.whileWindowOpen)
                    Text("always").tag(ActivityRecordingPolicy.always)
                } label: {
                    Text("Record activity")
                }
                .fixedSize()

                Toggle("Open at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
            }

            SettingsCard(title: "Syncthing",
                         version: syncthingVersion
                             ?? (daemonSettings.mode == .managed ? "Not installed" : "—"),
                         versionURL: syncthingVersion.flatMap {
                             syncthingSource.releaseNotesURL(for: $0)
                         },
                         icon: { Image("SyncthingLogo").resizable().scaledToFit() }) {
                // The mode determines everything below it in the card, so it
                // leads. Sentence-form row ("Syncthing is managed by …"): the
                // shared subject lives in the label, so the two options differ
                // only in the dimension being chosen — who manages. Values are
                // lowercase because they continue the label's sentence.
                Picker(selection: $daemonSettings.mode) {
                    Text("managed by this app").tag(DaemonMode.managed)
                    Text("managed by me").tag(DaemonMode.selfManaged)
                } label: {
                    Text("Syncthing is")
                }
                .fixedSize()

                switch daemonSettings.mode {
                case .managed:
                    Divider()

                    UpdateControls(source: syncthingSource, settings: syncthingSettings)

                    Divider()

                    FullDiskAccessSection(binaryURL: ReleaseUpdater.installedBinaryURL,
                                          attention: fdaAttention)
                case .selfManaged:
                    Text("Syncthing Menu connects to a Syncthing you run and manage "
                         + "yourself on this Mac. Starting, stopping, and updates "
                         + "are up to you.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    SelfManagedConnectionSection(daemonSettings: daemonSettings,
                                                 status: status)

                    // Attention-only (no standing section — decided): folders the
                    // connected daemon reports it can't read, with the guidance we
                    // can honestly give for a binary we didn't install.
                    if let fdaAttention {
                        Divider()
                        SelfManagedAccessAlert(message: fdaAttention)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// The update controls shared by both cards: status + action, the last-checked line,
/// and the two preference toggles. The "major updates require approval" note shows
/// only on a channel that gates majors (Syncthing).
private struct UpdateControls: View {
    @ObservedObject var source: UpdateSource
    @ObservedObject var settings: UpdateChannelSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                UpdateStatusRow(source: source, coordinator: source.coordinator)
                if let lastChecked = settings.lastChecked {
                    // Re-render each minute so the relative time stays live (computed
                    // against the current moment via context.date). Minute cadence
                    // matches the formatter's finest unit; TimelineView pauses while the
                    // window is closed/off-screen.
                    TimelineView(.periodic(from: lastChecked, by: 60)) { context in
                        Text("Last checked \(RelativeTime.ago(lastChecked, now: context.date))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Toggle("Automatically check for updates", isOn: $settings.autoCheckEnabled)
            Toggle("Install updates automatically", isOn: $settings.autoInstallEnabled)
                .disabled(!settings.autoCheckEnabled)   // slaved to auto-check
            if source.gatesMajorUpdates {
                Text("Major \(source.name) updates require approval")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The self-managed connection body: address + API key fields and a live
/// connection-status row. There is no Test Connection button — the session
/// probes continuously (field edits re-arm it within a beat), and the status
/// row *is* the result, so the card tests itself and reports honestly.
private struct SelfManagedConnectionSection: View {
    @ObservedObject var daemonSettings: DaemonModeSettings
    @ObservedObject var status: SyncthingStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Address")
                    // Local instances only, so the host isn't a question — it
                    // reads as part of the address; only the port is editable.
                    // The field starts filled with Syncthing's default; the
                    // placeholder appears only when cleared, and an empty
                    // field means exactly what the placeholder shows.
                    HStack(spacing: 5) {
                        Text("127.0.0.1 :")
                            .font(.body.monospacedDigit())
                        TextField(String(SelfManagedEndpoint.defaultPort),
                                  text: $daemonSettings.selfManagedPort)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                            .frame(width: 64)
                        Spacer(minLength: 0)
                    }
                }
                GridRow {
                    Text("API Key")
                    // Deliberately not a SecureField: the key is pasted, never
                    // memorized, and seeing it is the only way to confirm the
                    // paste — Syncthing's own UI shows it in the clear too.
                    // (Storage is the Keychain regardless.)
                    TextField("", text: $daemonSettings.selfManagedAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                }
            }

            // Answers the question every user has at exactly this moment.
            Text("Find the API key in Syncthing's web interface under "
                 + "Actions → Settings → General.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ConnectionStatusRow(status: status)
        }
    }
}

/// One connection-status row in the cards' shared status grammar (icon + text,
/// like the update rows): the session's live verdict, 1:1 on the display state.
private struct ConnectionStatusRow: View {
    @ObservedObject var status: SyncthingStatusModel

    private enum RowState {
        case notConfigured, connecting, connected, unreachable, keyRejected
    }

    private var rowState: RowState {
        switch status.display {
        case .notConfigured: .notConfigured
        case .unreachable: .unreachable
        case .keyRejected: .keyRejected
        case .running, .syncing, .scanning, .paused, .attention: .connected
        // .connecting, plus managed-mode states that can flash mid-switch.
        default: .connecting
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            switch rowState {
            case .notConfigured:
                Label("Not configured", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            case .connected:
                Label("Connected", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .unreachable:
                Label("Not reachable", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            case .keyRejected:
                Label("API key rejected", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }
            Spacer()
        }
    }
}

/// A titled card: icon + name on the left, current version (a release-notes link when
/// known) right-aligned in the header, and arbitrary content stacked below.
private struct SettingsCard<Icon: View, Content: View>: View {
    let title: String
    let version: String
    /// When set, the version reads as a link to that version's release notes.
    var versionURL: URL? = nil
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var content: () -> Content

    @ViewBuilder private var versionView: some View {
        if let versionURL {
            Link(version, destination: versionURL)
        } else {
            Text(version).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header lives inside the card with a divider to its content, so the title
            // and its controls read as one group.
            HStack(spacing: 8) {
                icon()
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.headline)
                Spacer()
                versionView
                    .font(.body.monospacedDigit())
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

/// One update-status row: the state (with icon) on the left, the contextual action
/// button on the right. An available update is tinted and its whole "X available"
/// string links to the new version's release notes; the prominent button draws the eye.
private struct UpdateStatusRow: View {
    @ObservedObject var source: UpdateSource
    /// Observed so the Update button disables live while the other channel installs.
    @ObservedObject var coordinator: UpdateInstallCoordinator

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
            Label("Not checked", systemImage: "questionmark.circle")
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
            let text = isMajor ? "\(version) available · major update" : "\(version) available"
            if let url = source.releaseNotesURL(for: version) {
                Link(destination: url) {
                    Label(text, systemImage: "arrow.down.circle.fill")
                }
                .foregroundStyle(Color.accentColor)
            } else {
                Label(text, systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        case .installing:
            // "Updating…", not "Installing…": on the app channel this state also
            // covers the consent dialog being open (nothing is installing yet).
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Updating…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch source.state {
        case .available:
            // "Update" for majors too: the click is the consent, and the "· major
            // update" text plus the approval note carry the distinction (no ellipsis —
            // the click acts immediately). Disabled while the other channel is
            // mid-install, since installs are serialized app-wide.
            Button("Update") {
                source.installAvailable()
            }
            .buttonStyle(.borderedProminent)
            .disabled(coordinator.installingChannel != nil)
        case .installing:
            EmptyView()
        case .checking:
            Button("Check Now") {}.disabled(true).buttonStyle(.borderedProminent)
        default:
            Button("Check Now") { source.checkNow() }.buttonStyle(.borderedProminent)
        }
    }
}
