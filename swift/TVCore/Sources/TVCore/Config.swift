import Foundation

/// Shared with the Go app: the JSON keys below are what sidebar.js and
/// settings.js read, so they must not drift from config.go's `json:` tags.

public struct Channel: Codable, Equatable, Sendable {
    public var title: String
    public var url: String
    public var region: String
    public var hide: [String]

    public init(title: String, url: String, region: String = "", hide: [String] = []) {
        self.title = title
        self.url = url
        self.region = region
        self.hide = hide
    }
}

public struct WindowConfig: Codable, Equatable, Sendable {
    public var title: String
    public var width: Int
    public var height: Int

    public init(title: String = "TV View", width: Int = 1200, height: Int = 900) {
        self.title = title
        self.width = width
        self.height = height
    }
}

public let defaultSeekSeconds = 10

public struct MediaConfig: Codable, Equatable, Sendable {
    public var seekSeconds: Int
    public var reverse: Bool

    public init(seekSeconds: Int = defaultSeekSeconds, reverse: Bool = false) {
        self.seekSeconds = seekSeconds
        self.reverse = reverse
    }
}

/// Region -> WireGuard file. `tunnels` holds the usable ones, `pending` the
/// regions whose file is not there yet (value: where it is expected), and
/// `declared` is what the file said, spelled as written, for saving back.
public struct VPNConfig: Equatable, Sendable {
    public var tunnels: [String: String] = [:]
    public var pending: [String: String] = [:]
    public var declared: [String: String] = [:]
}

public struct Config: Equatable, Sendable {
    public var window = WindowConfig()
    public var media = MediaConfig()
    public var userAgent = defaultUserAgent
    public var channels: [Channel] = []
    public var vpn: VPNConfig?
    /// Where this was read from; nil for the built-in defaults.
    public var path: String?

    public init() {}
}

/// Safari's string, deliberately (see NOTES.md): streaming sites branch hard on
/// the User-Agent, and the stock WKWebView one stalls them.
public let defaultUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15"

public struct ConfigError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
