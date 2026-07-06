import SwiftUI

/// A subtle external link to a version's release notes — the shared treatment used by
/// the About window and the Settings cards (the up-forward glyph at callout size,
/// quieter than a primary link). Renders nothing when the URL is nil, so callers can
/// pass an optional straight through.
struct ReleaseNotesLink: View {
    let url: URL?

    var body: some View {
        if let url {
            Link(destination: url) {
                Label("Release Notes", systemImage: "arrow.up.forward.square")
            }
            .font(.callout)
        }
    }
}
