import AppKit
import SwiftUI

/// The app icon as the system icon runtime renders it — the SINGLE source
/// for every in-app identity surface (Settings card, About, the Activity
/// titlebar). Derivative by construction: whatever `AppIcon.icon` produces
/// is what these surfaces show; there is no parallel mark asset to drift
/// out of sync (the old `AppMark` imageset and its generator are gone).
enum AppIconImage {
    /// The icon pre-sized to its display size in points, so AppKit's rep
    /// matching picks the nearest rendition instead of resampling the
    /// largest — resampling visibly dithers at small sizes (learned on the
    /// Activity titlebar, 2026-07-21).
    static func nsImage(points: CGFloat) -> NSImage {
        guard let image = NSApp.applicationIconImage?.copy() as? NSImage else { return NSImage() }
        image.size = NSSize(width: points, height: points)
        return image
    }

    static func view(points: CGFloat) -> Image {
        Image(nsImage: nsImage(points: points))
    }
}
