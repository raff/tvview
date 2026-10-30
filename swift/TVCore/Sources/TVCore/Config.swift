import Foundation

/// Shared with the Go app: the JSON keys below are what sidebar.js and
/// settings.js read, so they must not drift from config.go's `json:` tags.

public struct Channel: Codable, Equatable, Sendable {
    public var title: String
    public var url: String
    public var region: String
    public var hide: [String]
    /// Overrides the config's user_agent for this channel; empty means no override.
    public var userAgent: String
    /// CSS selector of the site player's own rewind button, clicked by the headphone
    /// previous-track button; empty means seek the video directly.
    public var rewindButton: String
    /// Same for the next-track button and for play/pause.
    public var forwardButton: String
    public var playButton: String

    public init(title: String, url: String, region: String = "", hide: [String] = [], userAgent: String = "", rewindButton: String = "", forwardButton: String = "", playButton: String = "") {
        self.title = title
        self.url = url
        self.region = region
        self.hide = hide
        self.userAgent = userAgent
        self.rewindButton = rewindButton
        self.forwardButton = forwardButton
        self.playButton = playButton
    }

    private enum CodingKeys: String, CodingKey {
        case title, url, region, hide
        case userAgent = "user_agent"
        case rewindButton = "rewind_button"
        case forwardButton = "forward_button"
        case playButton = "play_button"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        region = try c.decode(String.self, forKey: .region)
        hide = try c.decode([String].self, forKey: .hide)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? ""
        rewindButton = try c.decodeIfPresent(String.self, forKey: .rewindButton) ?? ""
        forwardButton = try c.decodeIfPresent(String.self, forKey: .forwardButton) ?? ""
        playButton = try c.decodeIfPresent(String.self, forKey: .playButton) ?? ""
    }

    /// user_agent is left out when empty, so the Go app's JSON shape is unchanged.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(url, forKey: .url)
        try c.encode(region, forKey: .region)
        try c.encode(hide, forKey: .hide)
        if !userAgent.isEmpty { try c.encode(userAgent, forKey: .userAgent) }
        if !rewindButton.isEmpty { try c.encode(rewindButton, forKey: .rewindButton) }
        if !forwardButton.isEmpty { try c.encode(forwardButton, forKey: .forwardButton) }
        if !playButton.isEmpty { try c.encode(playButton, forKey: .playButton) }
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
