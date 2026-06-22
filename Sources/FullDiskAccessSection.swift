import SwiftUI
import AppKit

/// A subsection of the Syncthing settings card explaining that syncing folders in
/// macOS protected locations needs Full Disk Access, with a help sheet that reveals
/// the managed Syncthing binary and opens the Privacy pane.
///
/// `attention` is nil in the normal informational state. When set to a message
/// (e.g. a folder Syncthing can't access), the section renders as an alert. The
/// detection that drives that is wired separately.
struct FullDiskAccessSection: View {
    let binaryURL: URL
    var attention: String? = nil
    @State private var showingHelp = false

    private var isAlert: Bool { attention != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isAlert ? "exclamationmark.triangle.fill" : "lock.shield")
                    .font(.title3)
                    .foregroundStyle(isAlert ? Color.orange : Color.secondary)
                Text(attention ?? "Syncing folders in macOS protected locations "
                     + "(e.g., Desktop, Documents, Pictures) may require \"Full Disk Access\"")
                    .font(.callout)
                    .foregroundStyle(isAlert ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(isAlert ? "Fix Full Disk Access…" : "Set Up Full Disk Access…") {
                showingHelp = true
            }
            .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $showingHelp) {
            FullDiskAccessHelp(binaryURL: binaryURL)
        }
    }
}

/// The nested help sheet: explanation, numbered steps, and one button that reveals
/// the Syncthing binary in Finder and opens the Full Disk Access pane.
private struct FullDiskAccessHelp: View {
    let binaryURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Full Disk Access")
                .font(.title2.bold())

            Text("Syncthing Menu downloads and runs the Syncthing app in the background. "
                 + "On some versions of macOS, Syncthing may need Full Disk Access to sync "
                 + "folders in protected locations — such as Desktop, Documents, Pictures, or "
                 + "external and network volumes.")
                .fixedSize(horizontal: false, vertical: true)

            // The entry to grant has the same name and icon as the standalone Syncthing
            // app, so call out which one — prominently, before the steps.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Grant access to the lowercase **syncthing** file with the terminal icon — that's the copy this app manages. If you also use the standalone **Syncthing** app, it's a different entry, and granting it won't help.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Click the button below — it reveals the syncthing file in Finder and "
                     + "opens Privacy & Security › Full Disk Access.")
                step(2, "Drag that syncthing file into the Full Disk Access list.")
                step(3, "Turn its switch on. Syncing resumes automatically — no restart needed.")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([binaryURL])
                if let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Reveal Syncthing & Open Settings", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(AllowsTerminationWhileModal())
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).")
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Clears `preventsApplicationTerminationWhenModal` on the hosting window, so a
/// sheet doesn't block Quit — the same thing AppKit does for Open panels and the
/// like (NSWindow default for that flag is `YES`).
private struct AllowsTerminationWhileModal: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.preventsApplicationTerminationWhenModal = false }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.preventsApplicationTerminationWhenModal = false
    }
}
