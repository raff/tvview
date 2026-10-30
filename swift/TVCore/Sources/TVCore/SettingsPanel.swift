import Foundation

// What the settings panel (settings.js) talks to: the two calls wvGetConfig and
// wvSaveConfig, as plain functions so they can be tested without a web view.
// A port of settings.go; the JSON shapes are identical.

public struct PanelConfig: Codable, Equatable {
    public var window: WindowConfig
    public var media: MediaConfig
    public var user_agent: String
    public var channels: [Channel]
}

struct SaveRequest: Decodable {
    var raw: String?
    var config: PanelConfig?
}

public struct SaveOutcome {
    /// What the panel gets back.
    public var response: [String: Any]
    /// The config now in force; nil when the save did not happen.
    public var config: Config?
}

public enum SettingsPanel {
    /// JSON-compatible object for any Encodable.
    public static func jsonObject<T: Encodable>(_ v: T) -> Any {
        guard let data = try? JSONEncoder().encode(v),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return NSNull() }
        return obj
    }

    /// wvGetConfig. Region names and states only: the panel never sees, and so
    /// can never send back, a tunnel's file path.
    public static func view(of cfg: Config, defaultText: String) -> [String: Any] {
        let target = ConfigPaths.saveTarget(cfg.path)
        let raw = target.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? defaultText

        let (tunnels, warnings) = cfg.reconciledTunnels()
        let regions: [[String: String]] = tunnels.keys.sorted().map { name in
            let v = tunnels[name]!
            let state = isPending(v) ? "pending"
                : ConfigPaths.isFile(ConfigPaths.resolveTunnel(v, cfgPath: cfg.path)) ? "ok" : "missing"
            return ["name": name, "state": state]
        }

        return [
            "config": jsonObject(PanelConfig(
                window: cfg.window, media: cfg.media, user_agent: cfg.userAgent, channels: cfg.channels)),
            "defaultUserAgent": defaultUserAgent,
            "regions": regions,
            "raw": raw,
            "path": Config.describe(target),
            "warnings": warnings,
        ]
    }

    /// wvSaveConfig. `running` is the VPN setup the app started with, to say
    /// whether a restart is needed; `liveScripts` is whether this host re-injects
    /// its page scripts on save (the Swift app does, so media and hide changes
    /// need no restart; the Go app cannot).
    public static func save(
        request: String, current: Config, running: VPNConfig?, liveScripts: Bool, liveVPN: Bool = false
    ) -> SaveOutcome {
        func fail(_ message: String) -> SaveOutcome {
            SaveOutcome(response: ["ok": false, "error": message], config: nil)
        }

        guard let req = try? JSONDecoder().decode(SaveRequest.self, from: Data(request.utf8)) else {
            return fail("bad request")
        }

        var warnings: [String] = []
        let target: String

        if let raw = req.raw {
            guard let t = ConfigPaths.saveTarget(current.path) else { return fail("nowhere to save the config") }
            target = t
            do {
                _ = try Config.parse(raw, path: target)
                try writeFileAtomic(target, Data(raw.utf8))
            } catch {
                return fail(error.localizedDescription)
            }
        } else if let c = req.config {
            var next = current
            next.window = c.window
            next.media = c.media
            next.userAgent = c.user_agent
            next.channels = c.channels
            for (i, ch) in next.channels.enumerated()
            where ch.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fail("channel \(i + 1) (\"\(ch.title)\") has no URL")
            }
            do {
                let saved = try next.save()
                target = saved.path
                warnings = saved.warnings
            } catch {
                return fail(error.localizedDescription)
            }
        } else {
            return fail("nothing to save")
        }

        // Reload from the file rather than trusting what was sent: this is the
        // config the next launch will see, defaults and tunnels included.
        let fresh: Config
        do {
            fresh = try Config.load(path: target, defaultText: "")
        } catch {
            return fail(error.localizedDescription)
        }

        return SaveOutcome(
            response: [
                "ok": true,
                "warnings": warnings,
                "restart": restartReasons(
                    old: current, new: fresh, running: running, liveScripts: liveScripts, liveVPN: liveVPN),
            ],
            config: fresh)
    }

    /// Changes that only apply on the next launch, because what they configure
    /// was built once at startup.
    public static func restartReasons(
        old: Config, new: Config, running: VPNConfig?, liveScripts: Bool, liveVPN: Bool = false
    ) -> [String] {
        var r: [String] = []
        if old.window.width != new.window.width || old.window.height != new.window.height {
            r.append("window size")
        }
        if !liveScripts {
            if old.media != new.media { r.append("media settings") }
            if old.channels.map({ [$0.url: $0.hide] }) != new.channels.map({ [$0.url: $0.hide] }) {
                r.append("hidden page elements")
            }
            let buttons: (Channel) -> [String: [String]] = { [$0.url: [$0.rewindButton, $0.forwardButton, $0.playButton]] }
            if old.channels.map(buttons) != new.channels.map(buttons) {
                r.append("player buttons")
            }
        }
        // A host that reads the config each time it needs a tunnel (the Swift app)
        // has nothing to restart; one that built its tunnel manager once does.
        if !liveVPN && (running?.tunnels != new.vpn?.tunnels || running?.pending != new.vpn?.pending) {
            r.append("VPN regions")
        }
        return r
    }
}
