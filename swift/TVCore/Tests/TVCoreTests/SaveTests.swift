import XCTest
@testable import TVCore

/// Mirrors config_save_test.go and settings_test.go.
final class SaveTests: XCTestCase {
    var home: String!
    var dir: String { home + "/cfg" }
    var path: String { dir + "/channels.yaml" }

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "tvcore-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/wireguard", withIntermediateDirectories: true)
        ConfigPaths.home = { [home] in home! }
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: home) }

    func touch(_ p: String) { FileManager.default.createFile(atPath: p, contents: Data("[Interface]\n".utf8)) }
    func write(_ text: String) throws -> Config {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return try Config.load(path: path, defaultText: "")
    }
    func read() -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    func testSaveReconcilesTunnels() throws {
        touch(dir + "/wireguard/IT.conf")   // was pending: gets its real path
        touch(dir + "/wireguard/FR.conf")   // unlisted: gets added
        touch(dir + "/other.conf")          // real path elsewhere: untouched
        var cfg = try write("""
        channels:
          - {title: Rai, url: "https://r", region: IT}
          - {title: DE, url: "https://d", region: DE}
        vpn:
          tunnels:
            IT: "### add IT.conf here"
            DE: \(dir)/other.conf
            ES: \(dir)/gone.conf
        """)
        // Added in the panel: a region the file has no entry for.
        cfg.channels.append(Channel(title: "BBC", url: "https://b", region: "UK"))

        let (target, warnings) = try cfg.save()
        XCTAssertEqual(target, path)

        let saved = try Config.load(path: path, defaultText: "")
        XCTAssertEqual(saved.vpn?.tunnels["IT"], dir + "/wireguard/IT.conf")
        XCTAssertEqual(saved.vpn?.tunnels["FR"], dir + "/wireguard/FR.conf")
        XCTAssertEqual(saved.vpn?.tunnels["DE"], dir + "/other.conf")
        XCTAssertEqual(saved.vpn?.tunnels["ES"], dir + "/gone.conf", "missing but kept")
        XCTAssertNotNil(saved.vpn?.pending["UK"])

        XCTAssertTrue(read().contains("add UK.conf here"))
        let joined = warnings.joined(separator: "\n")
        XCTAssertTrue(joined.contains("UK") && joined.contains("ES") && !joined.contains("IT"), joined)
    }

    func testSaveKeepsBackupAndRoundTrips() throws {
        let orig = """
        # my notes
        window: {title: Mine, width: 800, height: 600}
        media: {seek_seconds: 30, reverse: true}
        user_agent: custom/1.0
        channels:
          - {title: A, url: "https://a", hide: [".x", ".y"]}
          - {title: B, url: "https://b"}
        """
        let cfg = try write(orig)
        try cfg.save()
        XCTAssertEqual(try String(contentsOfFile: path + ".bak", encoding: .utf8), orig)
        let again = try Config.load(path: path, defaultText: "")
        XCTAssertEqual(again.window, cfg.window)
        XCTAssertEqual(again.media, cfg.media)
        XCTAssertEqual(again.userAgent, "custom/1.0")
        XCTAssertEqual(again.channels, cfg.channels)
        XCTAssertNil(again.vpn)
    }

    /// Strings that would change meaning if written bare must survive a round trip.
    func testAwkwardStringsRoundTrip() throws {
        var cfg = try write("channels:\n  - {title: A, url: \"https://a\"}\n")
        let titles = ["123", "true", "null", "### x", "a: b", "#hash", "NASA+", "it's", "\"q\"", "- dash", "é ü"]
        cfg.channels = titles.map { Channel(title: $0, url: "https://x/" + $0.count.description, hide: [$0]) }
        try cfg.save()
        let again = try Config.load(path: path, defaultText: "")
        XCTAssertEqual(again.channels.map(\.title), titles)
        XCTAssertEqual(again.channels.map { $0.hide[0] }, titles)
    }

    func testUserAgentIsOmittedWhenDefaultAndNotFolded() throws {
        var cfg = try write("channels:\n  - {title: A, url: \"https://a\"}\n")
        XCTAssertFalse(try cfg.marshal().yaml.contains("user_agent"))
        cfg.userAgent = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        try cfg.save()
        XCTAssertEqual(try Config.load(path: path, defaultText: "").userAgent, cfg.userAgent)
    }

    func testSaveRefusesBadConfig() throws {
        var cfg = try write("channels:\n  - {title: A, url: \"https://a\"}\n")
        let before = read()
        cfg.channels = []
        XCTAssertThrowsError(try cfg.save())
        XCTAssertEqual(read(), before, "a failed save must not touch the file")
    }

    // MARK: panel

    func panelRequest(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func testViewHidesPaths() throws {
        let cfg = try write("""
        channels:
          - {title: Rai, url: "https://r", region: IT}
        vpn:
          tunnels:
            IT: "### add IT.conf here"
        """)
        touch(dir + "/wireguard/FR.conf")
        let view = SettingsPanel.view(of: cfg, defaultText: "")
        let regions = view["regions"] as! [[String: String]]
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: regions.map { ($0["name"]!, $0["state"]!) }),
                       ["IT": "pending", "FR": "ok"])
        let editable = try JSONSerialization.data(withJSONObject: [view["config"]!, view["regions"]!])
        let text = String(data: editable, encoding: .utf8)!
        XCTAssertFalse(text.contains(dir) || text.contains(".conf"), text)
    }

    func testSaveFromPanelStructured() throws {
        let cfg = try write("""
        window: {title: T, width: 800, height: 600}
        channels:
          - {title: A, url: "https://a"}
          - {title: B, url: "https://b"}
        """)
        let out = SettingsPanel.save(
            request: panelRequest(["config": [
                "window": ["title": "New", "width": 900, "height": 600],
                "media": ["seekSeconds": 15, "reverse": false],
                "user_agent": "",
                "channels": [
                    ["title": "B", "url": "https://b", "region": "", "hide": [".x"]],
                    ["title": "C", "url": "https://c", "region": "IT", "hide": []],
                ],
            ]]),
            current: cfg, running: cfg.vpn, liveScripts: true)

        XCTAssertEqual(out.response["ok"] as? Bool, true, "\(out.response)")
        XCTAssertEqual(out.config?.channels.map(\.title), ["B", "C"])
        XCTAssertEqual(out.config?.window.title, "New")
        let restart = out.response["restart"] as! [String]
        XCTAssertEqual(Set(restart), ["window size", "VPN regions"], "media and hide are live in Swift")
        let warnings = out.response["warnings"] as! [String]
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("IT"))

        let goHost = SettingsPanel.restartReasons(old: cfg, new: out.config!, running: cfg.vpn, liveScripts: false)
        XCTAssertTrue(goHost.contains("media settings") && goHost.contains("hidden page elements"))

        // The Swift app reads the live config each time it needs a tunnel, so
        // changed regions need no restart there.
        let swiftApp = SettingsPanel.restartReasons(
            old: cfg, new: out.config!, running: cfg.vpn, liveScripts: true, liveVPN: true)
        XCTAssertEqual(swiftApp, ["window size"])
    }

    func testSaveFromPanelRejects() throws {
        let cfg = try write("channels:\n  - {title: A, url: \"https://a\"}\n")
        let before = read()
        let bad: [String: [String: Any]] = [
            "no url": ["config": ["window": ["title": "T", "width": 1, "height": 1], "media": ["seekSeconds": 1, "reverse": false],
                                  "user_agent": "", "channels": [["title": "x", "url": " ", "region": "", "hide": []]]]],
            "no channels": ["config": ["window": ["title": "T", "width": 1, "height": 1], "media": ["seekSeconds": 1, "reverse": false],
                                       "user_agent": "", "channels": []]],
            "bad raw": ["raw": "channels: ["],
            "empty": [:],
        ]
        for (name, body) in bad {
            let out = SettingsPanel.save(request: panelRequest(body), current: cfg, running: nil, liveScripts: true)
            XCTAssertEqual(out.response["ok"] as? Bool, false, name)
            XCTAssertNil(out.config, name)
        }
        XCTAssertEqual(read(), before, "a refused save changed the file")
    }

    func testSaveFromPanelRawKeepsTextAsTyped() throws {
        let cfg = try write("channels:\n  - {title: A, url: \"https://a\"}\n")
        let raw = "# keep me\nchannels:\n  - {title: Z, url: \"https://z\"}\n"
        let out = SettingsPanel.save(request: panelRequest(["raw": raw]), current: cfg, running: nil, liveScripts: true)
        XCTAssertEqual(out.response["ok"] as? Bool, true)
        XCTAssertEqual(read(), raw)
        XCTAssertEqual(out.config?.channels[0].title, "Z")
    }
}
