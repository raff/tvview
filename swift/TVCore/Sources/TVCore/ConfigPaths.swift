import Foundation

/// Where configs live. Mirrors config.go's search order and save target.
public enum ConfigPaths {
    /// Home directory. A variable so tests can point it somewhere private.
    nonisolated(unsafe) public static var home: () -> String = { NSHomeDirectory() }

    public static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return (home() as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }

    #if os(macOS)
    /// The tvview folder in iCloud Drive, which a Mac exposes as a plain
    /// directory. Never created for the user: the folder existing is the opt-in.
    public static func iCloudDir() -> String {
        (home() as NSString).appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/tvview")
    }

    /// $XDG_CONFIG_HOME/tvview, default ~/.config/tvview.
    public static func userConfigDir() -> String {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("tvview")
        }
        return (home() as NSString).appendingPathComponent(".config/tvview")
    }

    public static func searchPaths() -> [String] {
        [iCloudDir(), userConfigDir()].flatMap { dir in
            ["channels.yaml", "channels.yml"].map { (dir as NSString).appendingPathComponent($0) }
        }
    }
    #else
    /// iOS: the app's Documents folder, which Files can show.
    public static func documentsDir() -> String {
        (home() as NSString).appendingPathComponent("Documents")
    }

    public static func searchPaths() -> [String] {
        ["channels.yaml", "channels.yml"].map { (documentsDir() as NSString).appendingPathComponent($0) }
    }
    #endif

    /// Where a config loaded from `path` is written back; for the built-in
    /// defaults, where seeding would put them.
    public static func saveTarget(_ path: String?) -> String? {
        if let path, !path.isEmpty { return path }
        #if os(macOS)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: iCloudDir(), isDirectory: &isDir), isDir.boolValue {
            return (iCloudDir() as NSString).appendingPathComponent("channels.yaml")
        }
        return (userConfigDir() as NSString).appendingPathComponent("channels.yaml")
        #else
        return (documentsDir() as NSString).appendingPathComponent("channels.yaml")
        #endif
    }

    /// Folder beside the config where region files live.
    public static func wireguardDir(_ path: String?) -> String? {
        guard let target = saveTarget(path) else { return nil }
        return ((target as NSString).deletingLastPathComponent as NSString).appendingPathComponent("wireguard")
    }

    /// Where the file for `region` is expected, or nil when the name could not
    /// safely be one (it must be a bare file name: what it names is read as a
    /// WireGuard config).
    public static func pendingPath(_ cfgPath: String?, region: String) -> String? {
        guard let dir = wireguardDir(cfgPath), !region.isEmpty,
              region == (region as NSString).lastPathComponent, region != ".", region != ".."
        else { return nil }
        return (dir as NSString).appendingPathComponent(region + ".conf")
    }

    public static func isFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }
}

/// A `tunnels` value starting with this (or empty) means "the file for this
/// region isn't here yet". Same convention as config.go.
public let pendingPrefix = "###"

public func isPending(_ v: String) -> Bool { v.isEmpty || v.hasPrefix(pendingPrefix) }
