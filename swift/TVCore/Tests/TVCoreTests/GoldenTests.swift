import XCTest
@testable import TVCore

/// Runs testdata/golden, the cases the Go app runs too (golden_test.go): the
/// same before-file and panel edit must come out meaning the same thing.
final class GoldenTests: XCTestCase {
    var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "tvcore-golden-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        ConfigPaths.home = { [home] in home! }
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: home) }

    static var goldenDir: URL {
        URL(fileURLWithPath: #filePath)  // swift/TVCore/Tests/TVCoreTests/GoldenTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("testdata/golden")
    }

    func testGoldenCases() throws {
        let fm = FileManager.default
        let cases = try fm.contentsOfDirectory(atPath: Self.goldenDir.path).sorted().filter {
            fm.fileExists(atPath: Self.goldenDir.appendingPathComponent($0 + "/before.yaml").path)
        }
        XCTAssertGreaterThanOrEqual(cases.count, 6, "golden cases not found")
        for name in cases {
            // A fresh home per case: tearDown only runs once.
            let h = home + "/" + name
            ConfigPaths.home = { h }
            try run(name, home: h)
        }
    }

    func run(_ name: String, home h: String) throws {
        let fm = FileManager.default
        let caseDir = Self.goldenDir.appendingPathComponent(name)
        let dir = h + "/cfg"
        let path = dir + "/channels.yaml"
        try fm.createDirectory(atPath: dir + "/wireguard", withIntermediateDirectories: true)

        let before = try String(contentsOf: caseDir.appendingPathComponent("before.yaml"), encoding: .utf8)
        try before.write(toFile: path, atomically: true, encoding: .utf8)
        if let names = try? String(contentsOf: caseDir.appendingPathComponent("wireguard.txt"), encoding: .utf8) {
            for n in names.split(whereSeparator: \.isWhitespace) {
                fm.createFile(atPath: dir + "/wireguard/" + n, contents: Data("[Interface]\n".utf8))
            }
        }

        var cfg = try Config.load(path: path, defaultText: "")
        if let raw = try? Data(contentsOf: caseDir.appendingPathComponent("edit.json")) {
            let edit = try JSONDecoder().decode(PanelConfig.self, from: raw)
            cfg.window = edit.window
            cfg.media = edit.media
            cfg.userAgent = edit.user_agent.isEmpty ? defaultUserAgent : edit.user_agent
            cfg.channels = edit.channels
        }

        let (_, warnings) = try cfg.save()
        let saved = try Config.load(path: path, defaultText: "")

        let got: [String: Any] = [
            "config": SettingsPanel.jsonObject(PanelConfig(
                window: saved.window, media: saved.media, user_agent: saved.userAgent, channels: saved.channels)),
            "tunnels": saved.vpn?.declared as Any? ?? NSNull(),
            "warnings": warnings.map { $0.replacingOccurrences(of: h, with: "$HOME") }.sorted(),
        ]
        let want = try JSONSerialization.jsonObject(
            with: Data(contentsOf: caseDir.appendingPathComponent("expected.json")))

        // Round trip through JSON so both sides are plain NSNumber/NSString.
        let gotPlain = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: got))
        XCTAssertTrue((gotPlain as AnyObject).isEqual(want),
                      "\(name): saved state differs from expected.json\n--- got\n\(pretty(gotPlain))\n--- want\n\(pretty(want))")
    }

    func pretty(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(o)"
    }
}
