import Foundation
import Yams

// The file's own layout. Everything optional: an older or hand-written file
// with keys missing still loads, and defaults fill in (as in config.go).
private struct FileDoc: Decodable {
    struct Win: Decodable { var title: String?; var width: Int?; var height: Int? }
    struct Med: Decodable { var seek_seconds: Int?; var reverse: Bool? }
    struct VPN: Decodable { var tunnels: [String: String?]? }
    struct Chan: Decodable { var title: String?; var url: String?; var region: String?; var hide: [String]? }

    var window: Win?
    var media: Med?
    var user_agent: String?
    var vpn: VPN?
    var channels: [Chan]?
}

extension Config {
    /// Loads from `path` when given, otherwise from the first location in the
    /// search order that exists, falling back to `defaultText`.
    public static func load(path: String? = nil, defaultText: String) throws -> Config {
        if let path {
            return try parse(String(contentsOfFile: path, encoding: .utf8), path: path)
        }
        for p in ConfigPaths.searchPaths() where FileManager.default.fileExists(atPath: p) {
            return try parse(String(contentsOfFile: p, encoding: .utf8), path: p)
        }
        return try parse(defaultText, path: nil)
    }

    /// parseConfig in config.go.
    public static func parse(_ text: String, path: String?) throws -> Config {
        let doc: FileDoc
        do {
            doc = try YAMLDecoder().decode(FileDoc.self, from: text)
        } catch {
            throw ConfigError("parsing \(describe(path)): \(error)")
        }

        var cfg = Config()
        cfg.path = path

        cfg.window.title = doc.window?.title.flatMap { $0.isEmpty ? nil : $0 } ?? "TV View"
        cfg.window.width = (doc.window?.width ?? 0) > 0 ? doc.window!.width! : 1200
        cfg.window.height = (doc.window?.height ?? 0) > 0 ? doc.window!.height! : 900
        cfg.media.seekSeconds = (doc.media?.seek_seconds ?? 0) > 0 ? doc.media!.seek_seconds! : defaultSeekSeconds
        cfg.media.reverse = doc.media?.reverse ?? false

        let ua = (doc.user_agent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.userAgent = ua.isEmpty ? defaultUserAgent : ua

        for c in doc.channels ?? [] {
            let url = (c.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if url.isEmpty { continue }
            let title = (c.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.channels.append(Channel(
                title: title.isEmpty ? url : title,
                url: url,
                region: (c.region ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                hide: (c.hide ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            ))
        }
        if cfg.channels.isEmpty {
            throw ConfigError("\(describe(path)) defines no channels with a url")
        }

        if let v = doc.vpn {
            cfg.vpn = VPNConfig()
            for (region, value) in v.tunnels ?? [:] {
                cfg.vpn!.declared[region] = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        try cfg.checkVPN()
        return cfg
    }

    /// checkVPN in config.go: validates the vpn block against the channels that
    /// use it, and splits tunnels into usable and pending.
    mutating func checkVPN() throws {
        let name = Config.describe(path)
        guard var vpn else {
            if let c = channels.first(where: { !$0.region.isEmpty }) {
                throw ConfigError("\(name): channel \"\(c.title)\" sets region \"\(c.region)\" but the file has no vpn block")
            }
            return
        }
        if vpn.declared.isEmpty {
            throw ConfigError("\(name): vpn needs at least one entry under tunnels")
        }

        for (region, p) in vpn.declared {
            if !isPending(p) {
                vpn.tunnels[region] = ConfigPaths.resolveTunnel(p, cfgPath: path)
                continue
            }
            // Not an error: it becomes usable the moment the file lands, with
            // no save in between.
            let want = ConfigPaths.pendingPath(path, region: region)
            if let want, ConfigPaths.isFile(want) {
                vpn.tunnels[region] = want
            } else {
                vpn.pending[region] = want ?? ""
            }
        }

        for c in channels where !c.region.isEmpty {
            if vpn.tunnels[c.region] == nil && vpn.pending[c.region] == nil {
                throw ConfigError("\(name): channel \"\(c.title)\" sets region \"\(c.region)\" but vpn.tunnels has no entry for it")
            }
        }
        self.vpn = vpn
    }

    static func describe(_ path: String?) -> String {
        path ?? "the built-in channels.yaml"
    }
}
