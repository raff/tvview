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

    /// On an iPhone or iPad the tunnel is the system VPN (a packet tunnel extension): it uses
    /// the real network stack, which the CDNs that drop a userspace one accept, at the price of
    /// being device-wide while it is up. The simulator cannot run a packet tunnel, and macOS
    /// has vpnhelper, so both keep their own tunnels.
    #if os(iOS) && !targetEnvironment(simulator)
    static let usesSystemVPN = true
    private let system = SystemTunnel()
    #else
    static let usesSystemVPN = false
    #endif

    /// Makes `region` the one the web view uses, starting its tunnel on first use.
    /// An empty region clears the proxy and leaves every tunnel up.
    func ensure(_ region: String, config: Config, store: WKWebsiteDataStore) async throws {
        #if os(iOS) && !targetEnvironment(simulator)
        // Not short-circuited on `current`: the VPN may have been left up by an earlier
        // run, and what matters is what the system says.
        try await ensureSystem(region, config: config, store: store)
        return
        #else
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
        #endif
    }

    #if os(iOS) && !targetEnvironment(simulator)
    private func ensureSystem(_ region: String, config: Config, store: WKWebsiteDataStore) async throws {
        store.proxyConfigurations = [] // a proxy from the in-process tunnel must never linger
        if region.isEmpty {
            await system.disconnect()
            current = ""
            return
        }
        let path = try configPath(for: region, config: config)
        Self.materialize(path)
        guard let conf = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw VPNError("could not read the WireGuard file for \(region) at \(path)")
        }
        try await system.connect(region: region, conf: conf)
        current = region
    }
    #endif

    /// Tunnels being started, so a second request for the same region (a double
    /// tap) waits for the first instead of starting another.
    private var starting: [String: Task<Int32, Error>] = [:]

    /// How long to wait for a tunnel before saying so. The start itself cannot be
    /// cancelled and carries on; its result is kept for the next try.
    ///
    /// On macOS the first start of a region shows the administrator password
    /// dialog (vpnhelper), which takes as long as the person does.
    #if os(macOS)
    private static let startTimeout = 120.0
    #else
    private static let startTimeout = 20.0
    #endif

    /// The `.conf` for `region`, or the reason there is none (the same words on every platform).
    private func configPath(for region: String, config: Config) throws -> String {
        guard let vpn = config.vpn else { throw VPNError("no vpn block in the config") }
        guard let path = vpn.tunnels[region] else {
            if let want = vpn.pending[region] {
                throw VPNError("no WireGuard file for \(region) yet: add \(want)")
            }
            throw VPNError("no wireguard config for region \"\(region)\"")
        }
        return path
    }

    private func tunnel(for region: String, config: Config) async throws -> Int32 {
        if let port = ports[region] { return port }

        let start: Task<Int32, Error>
        if let running = starting[region] {
            start = running
        } else {
            let path = try configPath(for: region, config: config)

            // Bringing the device up can take a moment: not on the main thread.
            start = Task.detached {
                Self.materialize(path)
                var err = [CChar](repeating: 0, count: 512)
                let port = TVVPNStart(path, &err, Int32(err.count))
                if port < 0 { throw VPNError("starting wireguard for \(region): \(String(cString: err))") }
                return port
            }
            starting[region] = start
            // Record the outcome whenever it arrives, even after a timeout.
            Task { [weak self] in
                let port = try? await start.value
                self?.starting[region] = nil
                if let port { self?.ports[region] = port }
            }
        }

        return try await Self.wait(for: start, seconds: Self.startTimeout, region: region)
    }

    private static func wait(for task: Task<Int32, Error>, seconds: Double, region: String) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let once = Once()
            Task {
                do {
                    let port = try await task.value
                    if once.claim() { cont.resume(returning: port) }
                } catch {
                    if once.claim() { cont.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() {
                    cont.resume(throwing: VPNError(
                        "The \(region) tunnel did not come up within \(Int(seconds)) s. Check the network, and that its .conf file has finished downloading from iCloud; tap the channel to try again."))
                }
            }
        }
    }
}

/// Lets exactly one of two racing tasks resume a continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

extension VPNManager {
    /// A file in iCloud Drive can be on the server only. A coordinated read makes
    /// the system bring it down, so WireGuard's plain open finds the contents.
    nonisolated static func materialize(_ path: String) {
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: URL(fileURLWithPath: path), options: [], error: &error) { url in
            _ = try? Data(contentsOf: url)
        }
    }
}

struct VPNError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
