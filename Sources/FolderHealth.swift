import Foundation

/// Folder-health state shared with the Settings UI: display names of folders
/// Syncthing currently can't access for permission reasons (macOS TCC). Fed from
/// `SyncthingMonitor`'s snapshot by AppDelegate; `FullDiskAccessSection` renders
/// a non-empty list as its alert state.
final class FolderHealth: ObservableObject {
    @Published var permissionErrorFolders: [String] = []
}
