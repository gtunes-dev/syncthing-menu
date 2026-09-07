import AppKit
import Foundation
import Testing
@testable import SyncthingMenu

/// The menu's Folders and Devices lists, rendered from a monitor snapshot:
/// row order and marks, each row's verb submenu, the list items' marks, the
/// bulk verbs' state, and the verbs' wiring back to the owner. A real
/// `StatusItemController` (it creates a status item in the test host's menu
/// bar; harmless) — the menus are read directly, never shown.
@MainActor
struct StatusItemControllerTests {
    typealias Snapshot = SyncthingMonitor.Snapshot

    private func makeController() -> StatusItemController {
        StatusItemController(status: SyncthingStatusModel(), onOpenSettings: {}, onAbout: {})
    }

    private func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    /// Fire a verb the way a click would: the item's action on its target.
    private func click(_ item: NSMenuItem?) {
        guard let item, let action = item.action else { return }
        _ = (item.target as? NSObject)?.perform(action, with: item)
    }

    /// Both lists: bulk verb, separator, then rows in config order; row marks
    /// (attention outranks paused); each row's verbs; list-item marks.
    @Test func rendersListsFromSnapshot() {
        let controller = makeController()
        controller.update(snapshot: Snapshot(
            activity: .idle,
            folders: [.init(id: "f1", name: "Docs", path: "/d", paused: false, attention: false),
                      .init(id: "f2", name: "Photos", path: "/p", paused: true, attention: false),
                      .init(id: "f3", name: "Work", path: "/w", paused: true, attention: true)],
            devices: [.init(id: "A", name: "Laptop", paused: false),
                      .init(id: "B", name: "Office", paused: true)]))

        let folders = controller.foldersMenu.items
        #expect(folders.map(\.title) == ["Rescan All", "", "Docs", "Photos", "Work"])
        #expect(folders[1].isSeparatorItem)
        #expect(folders[0].isEnabled)
        #expect(folders[2...].map { $0.image?.accessibilityDescription }
                == [nil, "Paused", "Needs attention"])
        // Verbs: Open in Finder first; Rescan dimmed while paused; the
        // pause verb swaps its title.
        let docs = folders[2].submenu!.items
        #expect(docs.map(\.title) == ["Open in Finder", "Rescan", "", "Pause"])
        #expect(docs[1].isEnabled)
        let photos = folders[3].submenu!.items
        #expect(photos.map(\.title) == ["Open in Finder", "Rescan", "", "Resume"])
        #expect(!photos[1].isEnabled)

        let devices = controller.devicesMenu.items
        #expect(devices.map(\.title) == ["Pause All", "", "Laptop", "Office"])
        #expect(devices[0].isEnabled)
        #expect(devices[2...].map { $0.image?.accessibilityDescription } == [nil, "Paused"])
        #expect(devices[2].submenu!.items.map(\.title) == ["Pause"])
        #expect(devices[3].submenu!.items.map(\.title) == ["Resume"])

        // List items: attention outranks paused on Folders; any paused device
        // marks Devices.
        #expect(item(controller.menu, "Folders")?.image?.accessibilityDescription == "Needs attention")
        #expect(item(controller.menu, "Devices")?.image?.accessibilityDescription == "Paused")
    }

    /// No folders / no devices: the bulk verbs dim over a placeholder, and
    /// the list items carry no mark. Also the state at init.
    @Test func emptySnapshotDimsBulkVerbs() {
        let controller = makeController()
        for menu in [controller.foldersMenu, controller.devicesMenu] {
            #expect(menu.items.count == 3)
            #expect(!menu.items[0].isEnabled)
            #expect(!menu.items[2].isEnabled)
        }
        #expect(controller.foldersMenu.items[2].title == "No Folders")
        #expect(controller.devicesMenu.items[2].title == "No Devices")
        #expect(controller.devicesMenu.items[0].title == "Pause All")
        #expect(item(controller.menu, "Folders")?.image == nil)
        #expect(item(controller.menu, "Devices")?.image == nil)

        // A populated snapshot followed by the teardown's empty one returns
        // to the placeholders.
        controller.update(snapshot: Snapshot(
            folders: [.init(id: "f", name: "F", path: "/f", paused: true, attention: false)],
            devices: [.init(id: "A", name: "A", paused: true)]))
        controller.update(snapshot: Snapshot())
        #expect(controller.foldersMenu.items.map(\.title) == ["Rescan All", "", "No Folders"])
        #expect(controller.devicesMenu.items.map(\.title) == ["Pause All", "", "No Devices"])
        #expect(item(controller.menu, "Folders")?.image == nil)
    }

    /// Pause All ⇄ Resume All follows "every device paused" — the daemon's
    /// unscoped call's state — and the folder list's pause mark never
    /// affects it. The click sends the opposite of the current state.
    @Test func pauseAllFollowsAllDevicesPaused() {
        let controller = makeController()
        var toggles: [Bool] = []
        controller.onPauseToggle = { toggles.append($0) }

        controller.update(snapshot: Snapshot(
            folders: [.init(id: "f", name: "F", path: "/f", paused: true, attention: false)],
            devices: [.init(id: "A", name: "A", paused: true),
                      .init(id: "B", name: "B", paused: false)]))
        #expect(controller.devicesMenu.items[0].title == "Pause All")
        #expect(item(controller.menu, "Folders")?.image?.accessibilityDescription == "Paused")
        click(controller.devicesMenu.items[0])

        controller.update(snapshot: Snapshot(
            devices: [.init(id: "A", name: "A", paused: true),
                      .init(id: "B", name: "B", paused: true)]))
        #expect(controller.devicesMenu.items[0].title == "Resume All")
        click(controller.devicesMenu.items[0])

        #expect(toggles == [true, false])
    }

    /// Row verbs carry their object's identity (the id, never the name) and
    /// the pause verb sends the opposite of the row's state.
    @Test func rowVerbsCarryIdentity() {
        let controller = makeController()
        var rescans: [String] = []
        var folderPauses: [(String, Bool)] = []
        var devicePauses: [(String, Bool)] = []
        controller.onRescanFolder = { rescans.append($0) }
        controller.onSetFolderPaused = { folderPauses.append(($0, $1)) }
        controller.onSetDevicePaused = { devicePauses.append(($0, $1)) }

        controller.update(snapshot: Snapshot(
            folders: [.init(id: "f-run", name: "Same", path: "/a", paused: false, attention: false),
                      .init(id: "f-paused", name: "Same", path: "/b", paused: true, attention: false)],
            devices: [.init(id: "DEVICE-ID", name: "Laptop", paused: true)]))

        let running = controller.foldersMenu.items[2].submenu!.items
        let paused = controller.foldersMenu.items[3].submenu!.items
        click(running[1])                       // Rescan
        click(running[3])                       // Pause
        click(paused[3])                        // Resume
        click(controller.devicesMenu.items[2].submenu!.items[0])   // Resume

        #expect(rescans == ["f-run"])
        #expect(folderPauses.map(\.0) == ["f-run", "f-paused"])
        #expect(folderPauses.map(\.1) == [true, false])
        #expect(devicePauses.map(\.0) == ["DEVICE-ID"])
        #expect(devicePauses.map(\.1) == [false])
    }

    /// Rows are stable objects: an unchanged snapshot, an activity-only
    /// change (the lists don't render it), and a state flip on the same
    /// objects all keep the row and verb items — the flip updates them in
    /// place, so a submenu open under the pointer survives. Only a change to
    /// the set of objects replaces rows; the bulk verb item is stable always.
    @Test func rowsUpdateInPlace() {
        let controller = makeController()
        let snapshot = Snapshot(
            activity: .idle,
            folders: [.init(id: "f", name: "F", path: "/f", paused: false, attention: false)],
            devices: [.init(id: "A", name: "A", paused: false)])
        controller.update(snapshot: snapshot)
        let folderRow = controller.foldersMenu.items[2]
        let folderVerbs = folderRow.submenu!
        let deviceRow = controller.devicesMenu.items[2]
        let rescanAll = controller.foldersMenu.items[0]
        let pauseAll = controller.devicesMenu.items[0]

        controller.update(snapshot: snapshot)
        #expect(controller.foldersMenu.items[2] === folderRow)

        var busy = snapshot
        busy.activity = .syncing
        controller.update(snapshot: busy)
        #expect(controller.foldersMenu.items[2] === folderRow)
        #expect(controller.devicesMenu.items[2] === deviceRow)

        controller.update(snapshot: Snapshot(
            folders: [.init(id: "f", name: "Renamed", path: "/f", paused: true, attention: false)],
            devices: [.init(id: "A", name: "A", paused: true)]))
        #expect(controller.foldersMenu.items[2] === folderRow)
        #expect(folderRow.title == "Renamed")
        #expect(folderRow.image?.accessibilityDescription == "Paused")
        #expect(folderRow.submenu === folderVerbs)
        #expect(folderVerbs.items.map(\.title) == ["Open in Finder", "Rescan", "", "Resume"])
        #expect(!folderVerbs.items[1].isEnabled)
        #expect(controller.devicesMenu.items[2] === deviceRow)
        #expect(deviceRow.submenu!.items.map(\.title) == ["Resume"])
        #expect(controller.devicesMenu.items[0].title == "Resume All")

        controller.update(snapshot: Snapshot(
            folders: [.init(id: "g", name: "G", path: "/g", paused: false, attention: false)],
            devices: snapshot.devices))
        #expect(controller.foldersMenu.items[2] !== folderRow)
        #expect(controller.foldersMenu.items[0] === rescanAll)
        #expect(controller.devicesMenu.items[0] === pauseAll)
    }
}
