import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SyncthingMenu

/// Hosts the REAL Activity view in an off-screen window and checks the
/// row-height contract behind `UniformRowHeights`: every row kind measures
/// the table's nominal height, and the table is switched off AppKit's
/// automatic-row-height path (the estimated-height cache that re-enters
/// itself during SwiftUI's large row diffs — the "reentrant operation in
/// its NSTableView delegate" warning captured live 2026-09-07) and STAYS
/// off across later updates. Off-screen windows do lay out and create cell
/// views, so this is a real exercise of the table.
@MainActor
struct ActivityTableRowHeightTests {
    @Test func rowsAreUniformAndAutomaticHeightsStayOff() async throws {
        let server = FakeSyncthingServer()
        try server.start()
        defer { server.stop() }
        server.myID = "SELF"
        server.devices = [.init(deviceID: "SELF", paused: false),
                          .init(deviceID: "REMOTE7-FULL-ID", paused: false, name: "Laptop",
                                connected: true)]
        server.folders = [.init(id: "f1", label: "Folder One")]
        let api = SyncthingAPI(baseURL: URL(string: server.baseURL)!, apiKey: "test-key")

        let feed = ActivityFeed()
        feed.retrySleep = fastSleep
        defer { feed.disconnect() }
        let display = ActivityDisplayModel()
        let hosting = NSHostingView(rootView: ActivityView(feed: feed, display: display))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        // One row of every family: markers, a daemon event, file rows with
        // and without an icon, a failure.
        feed.setWindowVisible(true)
        feed.connect(api: api)
        try await expectEventually {
            server.requestedPaths.contains { $0.hasPrefix("/rest/events?") && $0.contains("timeout=50") }
        }
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "a.txt", "action": "modified", "type": "file"])
        server.pushEvent(type: "LocalChangeDetected",
                         data: ["folder": "f1", "path": "dir", "action": "modified", "type": "dir"])
        server.pushEvent(type: "ItemFinished",
                         data: ["folder": "f1", "item": "bad.txt", "action": "update",
                                "type": "file", "error": "permission denied"])
        server.pushEvent(type: "LocalIndexUpdated",
                         data: ["folder": "f1", "items": 1, "filenames": ["unknown-kind"]])
        server.pushEvent(type: "DevicePaused", data: ["device": "REMOTE7-FULL-ID"])
        try await expectEventually { feed.entries.count >= 7 }
        try await settle(hosting)

        guard let table = findTableView(in: hosting) else {
            Issue.record("no NSTableView in the hosted Activity view"); return
        }
        let nominal = table.rowHeight
        #expect(!table.usesAutomaticRowHeights, "UniformRowHeights did not apply")
        for row in 0..<table.numberOfRows {
            #expect(table.rect(ofRow: row).height == nominal, "row \(row) (\(feed.entries[row].kind))")
            let cell = table.view(atColumn: 1, row: row, makeIfNecessary: true)
            #expect(cell?.fittingSize.height == nominal, "cell \(row) fits \(cell?.fittingSize.height ?? -1)")
        }

        // A large update later: the setting survives SwiftUI's diff and the
        // new rows are uniform too.
        server.pushEvents((1...500).map { i in
            (type: "LocalChangeDetected",
             data: ["folder": "f1", "path": "more/\(i).txt", "action": "modified",
                    "type": "file"] as [String: Any])
        })
        try await expectEventually(timeout: 15) { feed.entries.count >= 507 }
        try await settle(hosting)
        #expect(!table.usesAutomaticRowHeights)
        #expect(table.rowHeight == nominal)
        #expect(table.numberOfRows == feed.entries.count)
        #expect(table.rect(ofRow: 250).height == nominal)
    }

    private func settle(_ hosting: NSHostingView<ActivityView>) async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
        hosting.layoutSubtreeIfNeeded()
        hosting.window?.contentView?.display()
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let found = findTableView(in: sub) { return found }
        }
        return nil
    }
}
