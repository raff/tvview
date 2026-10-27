import Foundation
import NetworkExtension

/// The iOS app's side of the system VPN: one VPN configuration ("TV View") whose
/// packet tunnel is the extension in App/Tunnel, switched between regions by
/// replacing the WireGuard config it carries. The extension does the work; this
/// saves the configuration, starts and stops it, and says why it did not start.
///
/// iOS shows a one-time "Add VPN Configurations" prompt the first time this saves.
@MainActor
final class SystemTunnel {
    static let providerBundleID = "io.github.raff.tvview.swift.tunnel"
    private var manager: NETunnelProviderManager?

    /// The region the VPN is up (or coming up) for, or "" when it is off.
    func activeRegion() async -> String {
        guard let m = try? await loadManager(create: false) else { return "" }
        switch m.connection.status {
        case .connected, .connecting, .reasserting:
            return (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["region"] as? String ?? ""
        default:
            return ""
        }
    }

    /// Brings the VPN up with `conf` (the WireGuard config text) for `region`, and returns
    /// once it is connected. One tunnel at a time: a different region replaces the running one.
    /// From then on a heartbeat tells the extension this app is still here; see stopNow().
    func connect(region: String, conf: String) async throws {
        try await connectOnce(region: region, conf: conf)
        startHeartbeat()
    }

    private var heartbeat: Task<Void, Never>?

    /// Every 15 s while this process is running, one byte to the extension. The extension
    /// stops the tunnel after a minute without it, so the VPN cannot outlive a killed or
    /// suspended app (iOS gives an app no reliable "I am being quit" moment).
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                self?.beat()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private func beat() {
        guard let m = manager, m.connection.status == .connected,
              let session = m.connection as? NETunnelProviderSession else { return }
        try? session.sendProviderMessage(Data([1])) { _ in }
    }

    /// Best effort, for the app being terminated while it can still act: ask the VPN to stop
    /// now, without waiting for the answer. (If the app is killed without notice, the
    /// extension's missing heartbeat does the same a minute later.)
    func stopNow() {
        heartbeat?.cancel()
        manager?.connection.stopVPNTunnel()
    }

    private func connectOnce(region: String, conf: String) async throws {
        let m = try await loadManager(create: true)!

        if m.connection.status == .connected, await activeRegion() == region { return }
        if ![.disconnected, .invalid].contains(m.connection.status) {
            m.connection.stopVPNTunnel()
            _ = await wait(for: [.disconnected, .invalid], on: m, timeout: 10)
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = region // what Settings shows under the VPN's name
        proto.providerConfiguration = ["conf": conf, "region": region]
        m.protocolConfiguration = proto
        m.localizedDescription = "TV View"
        m.isEnabled = true
        m.isOnDemandEnabled = false

        do {
            try await m.saveToPreferences()
            try await m.loadFromPreferences() // required before the first start after a save
        } catch {
            throw TunnelError(Self.explain(saveError: error))
        }

        NSLog("tvview: starting the system VPN for %@", region)
        do {
            try m.connection.startVPNTunnel()
        } catch {
            throw TunnelError("could not start the VPN: \(error.localizedDescription)")
        }

        // Wait for it to come up. Right after startVPNTunnel() the status still reads
        // "disconnected" for a moment, before it moves to "connecting": that is not a
        // failure (it was taken for one, and the VPN then connected anyway). "Disconnected"
        // only counts once the connection has been seen to start, or has not started at all
        // after a few seconds.
        //
        // Meanwhile keep asking the extension for its log: when it does fail, the process and
        // the log go with it, and this is the last thing it said.
        var lastLog = ""
        var sawStart = false
        let began = Date()
        let deadline = began.addingTimeInterval(30)
        var failed = false
        while Date() < deadline {
            switch m.connection.status {
            case .connected:
                return
            case .connecting, .reasserting, .disconnecting:
                sawStart = true
            case .disconnected, .invalid:
                if sawStart || Date().timeIntervalSince(began) > 5 { failed = true }
            @unknown default:
                break
            }
            if failed { break }
            if let log = await extensionLog(m, timeout: 1), !log.isEmpty { lastLog = log }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        throw TunnelError(await failureText(m, timedOut: !failed, lastLog: lastLog))
    }

    /// Turns the VPN off, if it is on.
    func disconnect() async {
        heartbeat?.cancel()
        guard let m = try? await loadManager(create: false) else { return }
        if [.disconnected, .invalid].contains(m.connection.status) { return }
        NSLog("tvview: stopping the system VPN")
        m.connection.stopVPNTunnel()
        _ = await wait(for: [.disconnected, .invalid], on: m, timeout: 10)
    }

    // MARK: details

    private func loadManager(create: Bool) async throws -> NETunnelProviderManager? {
        if let manager { return manager }
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        let ours = all.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID
        }
        manager = ours ?? (create ? NETunnelProviderManager() : nil)
        return manager
    }

    /// Polls rather than observing: the status is a property read, a few times a second,
    /// for at most `timeout`, and it keeps this a plain async function.
    private func wait(for wanted: Set<NEVPNStatus>, on m: NETunnelProviderManager, timeout: TimeInterval) async -> NEVPNStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while !wanted.contains(m.connection.status), Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return m.connection.status
    }

    /// What to tell the person when the VPN did not come up: the system's reason if it
    /// gave one, and the extension's own log if it is still there to ask.
    private func failureText(_ m: NETunnelProviderManager, timedOut: Bool, lastLog: String) async -> String {
        var parts: [String] = []
        if timedOut {
            parts.append("The VPN did not connect within 30 s.")
            m.connection.stopVPNTunnel()
        } else {
            parts.append("The VPN stopped while connecting.")
        }
        if let reason = await lastDisconnectError(m) { parts.append(reason) }
        var log = lastLog
        if log.isEmpty, let late = await extensionLog(m, timeout: 1) { log = late }
        if log.isEmpty {
            parts.append("The tunnel extension never reported anything, so it probably did not start.")
        } else {
            parts.append("Tunnel log:\n" + log.split(separator: "\n").suffix(12).joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    private func lastDisconnectError(_ m: NETunnelProviderManager) async -> String? {
        do {
            try await m.connection.fetchLastDisconnectError()
            return nil
        } catch {
            let e = error as NSError
            return "\(error.localizedDescription) (\(e.domain) \(e.code))"
        }
    }

    /// The extension's log, or nil if it does not answer within `timeout`: an extension that is
    /// not running never replies, and must not hold the caller up.
    private func extensionLog(_ m: NETunnelProviderManager, timeout: TimeInterval) async -> String? {
        guard let session = m.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { cont in
            let once = OnceFlag()
            do {
                try session.sendProviderMessage(Data([0])) { data in
                    if once.claim() { cont.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) }) }
                }
            } catch {
                if once.claim() { cont.resume(returning: nil) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// Declining the one-time "Add VPN Configurations" prompt arrives as an error from the save.
    private static func explain(saveError error: Error) -> String {
        let e = error as NSError
        if e.domain == NEVPNErrorDomain, e.code == NEVPNError.configurationReadWriteFailed.rawValue {
            return "iOS did not allow TV View to add a VPN configuration. Choose Allow when it asks, then try the channel again."
        }
        return "could not save the VPN configuration: \(error.localizedDescription)"
    }
}

/// Lets exactly one of two racing callbacks resume a continuation.
private final class OnceFlag: @unchecked Sendable {
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

struct TunnelError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
