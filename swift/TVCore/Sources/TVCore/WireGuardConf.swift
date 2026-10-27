import Foundation

/// The parts of a WireGuard `.conf` that configure the *interface*: addresses, DNS,
/// MTU, the endpoint and the routes. The tunnel itself (keys, peers) is built by the
/// Go library from the same text; this is only what a system VPN has to tell iOS
/// before packets can flow (NEPacketTunnelNetworkSettings).
public struct WireGuardConf: Equatable {
    public struct Prefix: Equatable {
        public var address: String
        public var length: Int
        public var isIPv6: Bool { address.contains(":") }

        public init(address: String, length: Int) {
            self.address = address
            self.length = length
        }

        /// Dotted-quad netmask for an IPv4 prefix length ("255.255.255.255" for /32).
        public var ipv4Mask: String {
            let bits = UInt32(max(0, min(32, length)))
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
            return (0..<4).map { String((mask >> (24 - 8 * UInt32($0))) & 0xff) }.joined(separator: ".")
        }
    }

    /// `Address =` (the tunnel's own addresses).
    public var addresses: [Prefix] = []
    /// `DNS =` entries that are IP addresses (search domains are not servers).
    public var dns: [String] = []
    public var mtu: Int?
    /// The first peer's `Endpoint`, host (name or address) and port.
    public var endpointHost: String?
    public var endpointPort: Int?
    /// The first peer's `AllowedIPs`: what is routed into the tunnel.
    public var allowedIPs: [Prefix] = []

    public static func parse(_ text: String) throws -> WireGuardConf {
        var conf = WireGuardConf()
        var section = ""
        var peers = 0

        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
                if section == "peer" { peers += 1 }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

            switch (section, key) {
            case ("interface", "address"):
                conf.addresses += items.compactMap { Self.prefix($0, defaultingTo: nil) }
            case ("interface", "dns"):
                conf.dns += items.filter { Self.isIPAddress($0) }
            case ("interface", "mtu"):
                conf.mtu = Int(value)
            case ("peer", "endpoint") where peers == 1:
                let (host, port) = Self.splitEndpoint(value)
                conf.endpointHost = host
                conf.endpointPort = port
            case ("peer", "allowedips") where peers == 1:
                conf.allowedIPs += items.compactMap { Self.prefix($0, defaultingTo: nil) }
            default:
                break
            }
        }

        if conf.addresses.isEmpty { throw ConfigError("the WireGuard config has no Address") }
        if conf.endpointHost == nil { throw ConfigError("the WireGuard config has no peer Endpoint") }
        return conf
    }

    /// `a/p`, or a bare address (a host route: /32 or /128). nil when it is not an address.
    static func prefix(_ s: String, defaultingTo: Int?) -> Prefix? {
        let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
        guard let address = parts.first, isIPAddress(address) else { return nil }
        let full = address.contains(":") ? 128 : 32
        let length = parts.count > 1 ? (Int(parts[1]) ?? full) : (defaultingTo ?? full)
        return Prefix(address: address, length: length)
    }

    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    /// `host:port`, `[v6]:port`, or just a host.
    static func splitEndpoint(_ s: String) -> (String, Int?) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        if let colon = s.lastIndex(of: ":"), s.filter({ $0 == ":" }).count == 1 {
            return (String(s[..<colon]), Int(s[s.index(after: colon)...]))
        }
        return (s, nil)
    }
}
