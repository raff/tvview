import Foundation
import TVCore

/// The folder the user picked in Files (normally the same iCloud Drive `tvview`
/// folder the Mac app reads), remembered across launches with a security-scoped
/// bookmark. An iOS app cannot reach into iCloud Drive on its own; a folder
/// handed to it through the picker is the way in.
enum ConfigFolder {
    private static let key = "configFolderBookmark"
    nonisolated(unsafe) private static var open: URL?

    /// Re-opens the remembered folder, if there is one. Call before loading the config.
    static func restore() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else {
            NSLog("tvview: the remembered config folder is no longer reachable")
            return
        }
        use(url)
        if stale { try? remember(url) }
    }

    /// Remembers a folder the picker returned, and starts using it.
    static func choose(_ url: URL) throws {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        try remember(url)
        // `use` takes its own access, so the one above can end here.
        use(url)
    }

    private static func remember(_ url: URL) throws {
        UserDefaults.standard.set(try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: key)
    }

    private static func use(_ url: URL) {
        open?.stopAccessingSecurityScopedResource()
        open = url.startAccessingSecurityScopedResource() ? url : nil
        ConfigPaths.configFolder = url.path
        prefetch(url)
    }

    /// Files in iCloud Drive can be on the server only. Reading through a file
    /// coordinator makes the system bring channels.yaml down first; a plain
    /// read would see a placeholder.
    private static func prefetch(_ folder: URL) {
        for name in ["channels.yaml", "channels.yml"] {
            let file = folder.appendingPathComponent(name)
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &error) { _ in }
        }
    }
}
