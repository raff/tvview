import Foundation
import NetworkExtension
import os
import TVCore
import TVVPN

/// The system VPN's tunnel, used on iPhone and iPad. The in-process tunnel
/// (swift/vpn/tunnel) is a userspace TCP stack, which some CDNs drop (BBC iPlayer);
/// a packet tunnel hands WireGuard the real network stack's packets instead.
///
/// The app passes the WireGuard `.conf` text in the VPN configuration's
/// `providerConfiguration["conf"]`: this process is sandboxed apart from the app
/// and cannot read the iCloud folder the config came from.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        Self.note("startTunnel")
        do {
            guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
                  let text = proto.providerConfiguration?["conf"] as? String
            else { throw Failure("the VPN configuration carries no WireGuard config") }
            Self.note("parsing the config (\(text.utf8.count) bytes)")
            let conf = try WireGuardConf.parse(text)
            Self.note("config parsed: \(conf.addresses.count) address(es), \(conf.dns.count) dns, \(conf.allowedIPs.count) route(s), endpoint \(conf.endpointHost ?? "?")")

            // First, while the network is still the real one: resolving the endpoint's
            // name after the settings below could be routed into a tunnel that is not up.
            Self.note("calling TVVPNTunnelPrepare")
            try Self.call { TVVPNTunnelPrepare(text, $0, $1) }
            Self.note("endpoint resolved")

            setTunnelNetworkSettings(Self.settings(for: conf)) { [weak self] error in
                if let error {
                    self?.fail(Failure("applying the network settings: \(error.localizedDescription)"), completionHandler)
                    return
                }
                Self.note("network settings applied")
                do {
                    Self.note("calling TVVPNTunnelStart")
                    try Self.call { TVVPNTunnelStart($0, $1) }
                    Self.note("wireguard started")
                    self?.startDeadMansSwitch()
                    completionHandler(nil)
                } catch {
                    self?.fail(error, completionHandler)
                }
            }
        } catch {
            fail(error, completionHandler)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Self.note("stopTunnel (reason \(reason.rawValue))")
        switchTimer?.cancel()
        TVVPNTunnelStop()
        completionHandler()
    }

    // MARK: the dead man's switch

    // iOS tells an app nothing when it is swiped away or killed, and a system VPN outlives
    // the app that started it. So the app says it is alive every few seconds, and this stops
    // the tunnel when it has not for a minute: a killed, crashed or suspended app takes the
    // VPN with it, and a brief trip to another app does not.
    private static let silenceLimit: TimeInterval = 60
    private var switchTimer: DispatchSourceTimer?
    private let beatLock = NSLock()
    private var lastBeat = Date()

    private func startDeadMansSwitch() {
        beat()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.beatLock.lock()
            let silent = Date().timeIntervalSince(self.lastBeat)
            self.beatLock.unlock()
            if silent > Self.silenceLimit {
                Self.note("the app has been silent for \(Int(silent)) s: stopping the VPN")
                self.switchTimer?.cancel()
                self.cancelTunnelWithError(nil)
            }
        }
        switchTimer = timer
        timer.resume()
    }

    private func beat() {
        beatLock.lock()
        lastBeat = Date()
        beatLock.unlock()
    }

    /// Reports a failed start. The process, and the log in it, goes away right after, and
    /// iOS does not pass an error's text back to the app: so wait a moment, during which
    /// the app (which asks for the log while it connects) can read why.
    private func fail(_ error: Error, _ completionHandler: @escaping (Error?) -> Void) {
        Self.note("FAILED: \(error.localizedDescription)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { completionHandler(error) }
    }

    /// Any message from the app is a request for the log: an extension has no console,
    /// so this is how the app finds out what went wrong in here.
    /// Two messages from the app: a single byte 1 is a heartbeat, anything else asks for the log.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if messageData == Data([1]) {
            beat()
            completionHandler?(nil)
            return
        }
        completionHandler?(Data((Self.steps() + Self.log()).utf8))
    }

    // MARK: this file's own log

    private static let notesLock = NSLock()
    private nonisolated(unsafe) static var notes: [String] = []

    /// A step this provider took. Kept apart from the Go library's log (which has
    /// wireguard-go's own lines) and returned with it.
    static func note(_ line: String) {
        // Also the system log (public, or it reads <private>), for when this process dies
        // before the app can ask: `log collect --device` then shows it.
        Logger(subsystem: "io.github.raff.tvview.tunnel", category: "extension").notice("\(line, privacy: .public)")
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        notesLock.lock()
        notes.append(f.string(from: Date()) + " " + line)
        if notes.count > 60 { notes.removeFirst(notes.count - 60) }
        notesLock.unlock()
    }

    private static func steps() -> String {
        notesLock.lock()
        defer { notesLock.unlock() }
        return notes.joined(separator: "\n") + "\n"
    }

    // MARK: network settings

    /// What iOS must know before packets can flow: the tunnel's addresses, which
    /// destinations go into it, and which DNS servers to ask.
    static func settings(for conf: WireGuardConf) -> NEPacketTunnelNetworkSettings {
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: conf.endpointHost ?? "127.0.0.1")

        let v4 = conf.addresses.filter { !$0.isIPv6 }
        if !v4.isEmpty {
            let ip = NEIPv4Settings(addresses: v4.map(\.address), subnetMasks: v4.map(\.ipv4Mask))
            ip.includedRoutes = conf.allowedIPs.filter { !$0.isIPv6 }.map {
                $0.length == 0 ? NEIPv4Route.default() : NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.ipv4Mask)
            }
            s.ipv4Settings = ip
        }

        // IPv6 only goes into the tunnel if the interface has an IPv6 address. A provider
        // that gives only an IPv4 one while allowing ::/0 would leave IPv6 outside the VPN,
        // where a geo-checked site sees the real address. So in that case give the
        // interface a private one: IPv6 then enters the tunnel and goes nowhere, and
        // apps fall back to IPv4.
        let v6 = conf.addresses.filter(\.isIPv6)
        let v6Routes = conf.allowedIPs.filter(\.isIPv6)
        if !v6.isEmpty || !v6Routes.isEmpty {
            let addresses = v6.isEmpty ? ["fd74:7676:6965:7700::2"] : v6.map(\.address)
            let lengths = v6.isEmpty ? [NSNumber(value: 128)] : v6.map { NSNumber(value: $0.length) }
            let ip = NEIPv6Settings(addresses: addresses, networkPrefixLengths: lengths)
            ip.includedRoutes = v6Routes.map {
                $0.length == 0 ? NEIPv6Route.default() : NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.length))
            }
            s.ipv6Settings = ip
        }

        if !conf.dns.isEmpty {
            let dns = NEDNSSettings(servers: conf.dns)
            dns.matchDomains = [""] // every name, not just ones under a search domain
            s.dnsSettings = dns
        }

        s.mtu = NSNumber(value: conf.mtu ?? 1380)
        return s
    }

    // MARK: the Go library

    /// Calls one of the library's functions that report failure as -1 with a message.
    private static func call(_ body: (UnsafeMutablePointer<CChar>, Int32) -> Int32) throws {
        var message = [CChar](repeating: 0, count: 512)
        let rc = message.withUnsafeMutableBufferPointer { body($0.baseAddress!, Int32($0.count)) }
        if rc < 0 {
            // With the last of the library's own log, which says what it was doing.
            let recent = log().split(separator: "\n").suffix(4).joined(separator: "\n")
            throw Failure(String(cString: message) + (recent.isEmpty ? "" : "\n" + recent))
        }
    }

    private static func log() -> String {
        var buf = [CChar](repeating: 0, count: 16 * 1024)
        let n = buf.withUnsafeMutableBufferPointer { Int(TVVPNTunnelLog($0.baseAddress!, Int32($0.count))) }
        return n > 0 ? String(cString: buf) : ""
    }
}

struct Failure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
