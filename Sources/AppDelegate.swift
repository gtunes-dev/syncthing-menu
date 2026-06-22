import AppKit
import Combine

/// Application lifecycle owner. Holds the menu-bar controller, the settings
/// window, and the update sources. Will later own the Syncthing subprocess
/// supervisor and the real update coordinator.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private let loginItem = LoginItemController()
    private let releaseUpdater = ReleaseUpdater()
    private let syncthingProcess = SyncthingProcess()
    private var cancellables = Set<AnyCancellable>()

    // Update sources, each conforming to the same `UpdateSource` surface: the app
    // updates via Sparkle, Syncthing via its REST API.
    private let appUpdateSource: UpdateSource = SparkleUpdateSource()
    private let syncthingUpdateSource = SyncthingUpdateSource(settings: .shared)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsController = SettingsWindowController(
            settings: .shared,
            appSource: appUpdateSource,
            syncthingSource: syncthingUpdateSource,
            loginItem: loginItem
        )
        settingsWindowController = settingsController

        statusItemController = StatusItemController(
            onOpenSettings: { settingsController.show() }
        )

        // Reflect the daemon's live state in the menu, and connect/disconnect the
        // Syncthing update source as the daemon comes up / goes down.
        syncthingProcess.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusItemController?.update(daemonState: state)
            switch state {
            case let .running(guiURL):
                if let key = self.syncthingProcess.apiKey {
                    self.syncthingUpdateSource.connect(baseURL: guiURL, apiKey: key)
                }
            case .stopped, .starting, .failed:
                self.syncthingUpdateSource.disconnect()
            }
        }

        // After an upgrade is applied, restart the daemon so its supervisor re-roots on
        // the canonical `syncthing` binary (fresh disclaim) instead of the renamed
        // `syncthing.old` that the running monitor would otherwise stay backed by.
        syncthingUpdateSource.onUpgradeApplied = { [weak self] in
            self?.syncthingProcess.restart()
        }

        // Surface "update available" on the menu-bar icon (Syncthing or app — the
        // icon does not distinguish between them).
        Publishers.CombineLatest(syncthingUpdateSource.$state, appUpdateSource.$state)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] syncState, appState in
                let available = Self.isUpdateAvailable(syncState) || Self.isUpdateAvailable(appState)
                self?.statusItemController?.setUpdateAvailable(available)
            }
            .store(in: &cancellables)

        // Bootstrap the binary (download + verify if needed), then launch the
        // managed daemon.
        Task {
            do {
                let url = try await releaseUpdater.bootstrapIfNeeded()
                NSLog("Syncthing binary ready at \(url.path)")
                DispatchQueue.main.async { self.syncthingProcess.start() }
            } catch {
                NSLog("Syncthing bootstrap failed: \(error)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncthingProcess.stop()
    }

    private static func isUpdateAvailable(_ state: UpdateState) -> Bool {
        if case .available = state { return true }
        return false
    }
}
