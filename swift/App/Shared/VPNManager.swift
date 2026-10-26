import Foundation
import Network
import TVCore
import TVVPN
import WebKit

/// One in-process WireGuard tunnel per region (the TVVPN library), each a local
/// SOCKS5 proxy, and the web view's data store pointed at whichever is current.
/// Only the web view's traffic goes through a tunnel; nothing else on the
/// device is touched. A tunnel is started the first time its region is needed
/// and left running until the app exits, as in the Go app.
///
/// Limitation, the reason the Go app moved to kernel interfaces: this is a
/// userspace TCP stack, and some CDNs (BBC iPlayer's asset delivery) drop its
/// connections. Most other sites are unaffected.
@MainActor
final class VPNManager {
    private var ports: [String: Int32] = [:]
    /// The region the web view is pointed at, "" for none.
    private(set) var current = ""

    /// Makes `region` the one the web view uses, starting its tunnel on first use.
    /// An empty region clears the proxy and leaves every tunnel up.
    func ensure(_ region: String, config: Config, store: WKWebsiteDataStore) async throws {
        if region == current { return }

        if region.isEmpty {
            store.proxyConfigurations = []
            current = ""
            return
        }

        let port = try await tunnel(for: region, config: config)
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw VPNError("tunnel for \(region) returned an unusable port")
        }
        store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: p))]
        current = region
    }

    private func tunnel(for region: String, config: Config) async throws -> Int32 {
        if let port = ports[region] { return port }

        guard let vpn = config.vpn else { throw VPNError("no vpn block in the config") }
        guard let path = vpn.tunnels[region] else {
            if let want = vpn.pending[region] {
                throw VPNError("no WireGuard file for \(region) yet: add \(want)")
            }
            throw VPNError("no wireguard config for region \"\(region)\"")
        }

        // Bringing the device up can take a moment: not on the main thread.
        let started: (port: Int32, error: String?) = await Task.detached {
            var err = [CChar](repeating: 0, count: 512)
            let port = TVVPNStart(path, &err, Int32(err.count))
            return (port, port < 0 ? String(cString: err) : nil)
        }.value

        if let message = started.error { throw VPNError("starting wireguard for \(region): \(message)") }
        ports[region] = started.port
        return started.port
    }
}

struct VPNError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
