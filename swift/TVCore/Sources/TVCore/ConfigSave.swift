import Foundation
import Yams

// Saving, a port of config_save.go. The same rules, in the same order, so a
// file saved by either app is read the same by both.

extension ConfigPaths {
    /// `path` spelled the way the config spells home-relative paths.
    public static func tildePath(_ path: String) -> String {
        let h = home()
        if path.hasPrefix(h + "/") { return "~/" + path.dropFirst(h.count + 1) }
        return path
    }
}

public func pendingText(_ region: String) -> String { "\(pendingPrefix) add \(region).conf here" }

extension Config {
    /// The vpn.tunnels to write, and warnings for what the user must do by
    /// hand. Never removes an entry or rewrites a real path; it only fills in:
    ///  1. a pending entry whose file now exists gets the real path;
    ///  2. a NAME.conf in the wireguard folder with no entry gets one;
    ///  3. a channel region with no entry gets a pending one.
    /// A missing file is a warning, never an error, so a config can be
    /// prepared before the files are in place.
    public func reconciledTunnels() -> (tunnels: [String: String], warnings: [String]) {
        var out = vpn?.declared ?? [:]
        let dir = ConfigPaths.wireguardDir(path)

        if let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for file in names.sorted() where file.hasSuffix(".conf") {
                let name = String(file.dropLast(".conf".count))
                if out[name].map(isPending) ?? true {
                    out[name] = ConfigPaths.tildePath((dir as NSString).appendingPathComponent(file))
                }
            }
        }

        for c in channels where !c.region.isEmpty && out[c.region] == nil {
            out[c.region] = pendingText(c.region)
        }

        var warnings: [String] = []
        for region in out.keys.sorted() {
            let v = out[region]!
            if isPending(v) {
                out[region] = pendingText(region) // canonical; also turns a bare null into text
                let where_ = ConfigPaths.pendingPath(path, region: region) ?? "the wireguard folder"
                warnings.append("region \(region) has no WireGuard file yet: add \(where_)")
            } else if !ConfigPaths.isFile(ConfigPaths.resolveTunnel(v, cfgPath: path)) {
                warnings.append("region \(region): \(v) does not exist")
            }
        }
        return (out, warnings)
    }

    /// Renders the config as channels.yaml, in the order a person would write
    /// it, with tunnels reconciled.
    public func marshal() throws -> (yaml: String, warnings: [String]) {
        // Yams leaves `null`, `~` and "" bare even when tagged as strings, which
        // would read back as null. Anything not plainly safe is double-quoted.
        func s(_ v: String) -> Node {
            .scalar(.init(v, Tag(.str), isPlainSafe(v) ? .any : .doubleQuoted))
        }
        func i(_ v: Int) -> Node { .scalar(.init(String(v), Tag(.int))) }
        func b(_ v: Bool) -> Node { .scalar(.init(v ? "true" : "false", Tag(.bool))) }
        func map(_ pairs: [(String, Node)]) -> Node {
            .mapping(.init(pairs.map { (s($0.0), $0.1) }, Tag(.map), .block))
        }
        func seq(_ items: [Node]) -> Node { .sequence(.init(items, Tag(.seq), .block)) }

        var top: [(String, Node)] = [
            ("window", map([("title", s(window.title)), ("width", i(window.width)), ("height", i(window.height))])),
        ]
        if userAgent != defaultUserAgent { top.append(("user_agent", s(userAgent))) }
        top.append(("media", map([("seek_seconds", i(media.seekSeconds)), ("reverse", b(media.reverse))])))

        let (tunnels, warnings) = reconciledTunnels()
        if !tunnels.isEmpty {
            let entries = tunnels.keys.sorted().map { ($0, s(tunnels[$0]!)) }
            top.append(("vpn", map([("tunnels", map(entries))])))
        }

        top.append(("channels", seq(channels.map { c in
            var f: [(String, Node)] = [("title", s(c.title)), ("url", s(c.url))]
            if !c.region.isEmpty { f.append(("region", s(c.region))) }
            if !c.hide.isEmpty { f.append(("hide", seq(c.hide.map(s)))) }
            if !c.rewindButton.isEmpty { f.append(("rewind_button", s(c.rewindButton))) }
            if !c.forwardButton.isEmpty { f.append(("forward_button", s(c.forwardButton))) }
            if !c.playButton.isEmpty { f.append(("play_button", s(c.playButton))) }
            if !c.userAgent.isEmpty { f.append(("user_agent", s(c.userAgent))) }
            return map(f)
        })))

        return (try Yams.serialize(node: map(top), width: -1, allowUnicode: true, sortKeys: false), warnings)
    }

    /// Writes the config to the file it was loaded from (or where seeding would
    /// put the built-in defaults). Nothing is written unless what would be
    /// written loads back cleanly; an existing file is kept as `.bak` first.
    /// Rewrites the file from structure, so comments are not kept (the .bak
    /// keeps them).
    @discardableResult
    public func save() throws -> (path: String, warnings: [String]) {
        guard let target = ConfigPaths.saveTarget(path) else {
            throw ConfigError("nowhere to save the config")
        }
        let (yaml, warnings) = try marshal()
        do {
            _ = try Config.parse(yaml, path: target)
        } catch {
            throw ConfigError("refusing to save: \(error.localizedDescription)")
        }
        try writeFileAtomic(target, Data(yaml.utf8))
        return (target, warnings)
    }
}

/// Replaces `target` with `data`, keeping the previous contents as
/// `target + ".bak"`. The original is copied, never moved, and the new file
/// only takes its place by a rename, so a failure at any step leaves it
/// untouched.
public func writeFileAtomic(_ target: String, _ data: Data) throws {
    let fm = FileManager.default
    let dir = (target as NSString).deletingLastPathComponent
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

    if fm.fileExists(atPath: target) {
        let bak = target + ".bak"
        do {
            if fm.fileExists(atPath: bak) { try fm.removeItem(atPath: bak) }
            try fm.copyItem(atPath: target, toPath: bak)
        } catch {
            throw ConfigError("writing backup: \(error.localizedDescription)")
        }
    }

    let tmp = (dir as NSString).appendingPathComponent(".channels-\(UUID().uuidString).tmp")
    do {
        try data.write(to: URL(fileURLWithPath: tmp))
        if fm.fileExists(atPath: target) {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: target), withItemAt: URL(fileURLWithPath: tmp))
        } else {
            try fm.moveItem(atPath: tmp, toPath: target)
        }
    } catch {
        try? fm.removeItem(atPath: tmp)
        throw error
    }
}

private let reservedPlain: Set<String> = ["null", "~", "true", "false", "yes", "no", "on", "off", "y", "n"]

/// Whether `v` can be written unquoted and still read back as the same string.
private func isPlainSafe(_ v: String) -> Bool {
    guard let first = v.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
    if reservedPlain.contains(v.lowercased()) { return false }
    if v.hasSuffix(" ") || v.contains(": ") || v.contains(" #") { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._/:+-@%&=?,"))
    return v.unicodeScalars.allSatisfy(allowed.contains)
}
