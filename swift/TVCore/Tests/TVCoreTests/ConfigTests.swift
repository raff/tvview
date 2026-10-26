import XCTest
@testable import TVCore

final class ConfigTests: XCTestCase {
    var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "tvcore-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        ConfigPaths.home = { [home] in home! }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
    }

    /// The Go app's own default config, which both apps must load.
    func testRepoDefaultConfigParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("channels.yaml")
        let text = try String(contentsOf: url, encoding: .utf8)
        let cfg = try Config.parse(text, path: nil)
        XCTAssertFalse(cfg.channels.isEmpty)
        XCTAssertNotNil(cfg.vpn)
    }

    func testDefaults() throws {
        let cfg = try Config.parse("channels:\n  - {url: \"https://a\"}\n", path: nil)
        XCTAssertEqual(cfg.window, WindowConfig(title: "TV View", width: 1200, height: 900))
        XCTAssertEqual(cfg.media, MediaConfig(seekSeconds: 10, reverse: false))
        XCTAssertEqual(cfg.userAgent, defaultUserAgent)
        XCTAssertEqual(cfg.channels[0].title, "https://a", "title falls back to the URL")
    }

    func testChannelsWithoutURLAreDropped() throws {
        let cfg = try Config.parse("channels:\n  - {title: x}\n  - {title: B, url: \" https://b \", hide: [\" .a \", \"\"]}\n", path: nil)
        XCTAssertEqual(cfg.channels, [Channel(title: "B", url: "https://b", hide: [".a"])])
    }

    func testNoChannelsIsAnError() {
        XCTAssertThrowsError(try Config.parse("window: {title: T}\n", path: nil))
    }

    func testRegionWithoutVPNBlockIsAnError() {
        XCTAssertThrowsError(try Config.parse("channels:\n  - {url: \"https://a\", region: IT}\n", path: nil))
    }

    func testRegionWithoutTunnelEntryIsAnError() {
        XCTAssertThrowsError(try Config.parse("""
        channels:
          - {url: "https://a", region: UK}
        vpn:
          tunnels:
            IT: ~/x.conf
        """, path: nil))
    }

    func testTildeExpandsInRealTunnelPaths() throws {
        let cfg = try Config.parse("""
        channels:
          - {url: "https://a", region: IT}
        vpn:
          tunnels:
            IT: ~/wg/IT.conf
        """, path: nil)
        XCTAssertEqual(cfg.vpn?.tunnels["IT"], home + "/wg/IT.conf")
        XCTAssertEqual(cfg.vpn?.declared["IT"], "~/wg/IT.conf")
    }

    #if os(macOS)
    /// Quoted, and the unquoted form (a YAML comment, so null): both pending.
    func testPendingTunnelsLoadAndResolveWhenTheFileAppears() throws {
        let dir = home + "/cfg"
        try FileManager.default.createDirectory(atPath: dir + "/wireguard", withIntermediateDirectories: true)
        let path = dir + "/channels.yaml"
        let text = """
        channels:
          - {title: Rai, url: "https://r", region: IT}
          - {title: BBC, url: "https://b", region: UK}
        vpn:
          tunnels:
            IT: ### add IT.conf here
            UK: "### add UK.conf here"
        """
        try text.write(toFile: path, atomically: true, encoding: .utf8)

        var cfg = try Config.load(path: path, defaultText: "")
        XCTAssertNil(cfg.vpn?.tunnels["IT"])
        XCTAssertEqual(cfg.vpn?.pending["IT"], dir + "/wireguard/IT.conf")
        XCTAssertEqual(cfg.vpn?.pending["UK"], dir + "/wireguard/UK.conf")

        FileManager.default.createFile(atPath: dir + "/wireguard/IT.conf", contents: Data("[Interface]\n".utf8))
        cfg = try Config.load(path: path, defaultText: "")
        XCTAssertEqual(cfg.vpn?.tunnels["IT"], dir + "/wireguard/IT.conf")
        XCTAssertNil(cfg.vpn?.pending["IT"])
        XCTAssertNotNil(cfg.vpn?.pending["UK"])
    }

    func testPendingRegionCannotEscapeTheFolder() {
        XCTAssertNil(ConfigPaths.pendingPath(home + "/cfg/channels.yaml", region: "../x"))
    }
    #endif

    func testJSONShapeMatchesTheGoApp() throws {
        let data = try JSONEncoder().encode(Channel(title: "A", url: "https://a", region: "IT", hide: [".x"]))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(obj.keys), ["title", "url", "region", "hide"])
        let m = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MediaConfig())) as! [String: Any]
        XCTAssertEqual(Set(m.keys), ["seekSeconds", "reverse"])
    }
}
