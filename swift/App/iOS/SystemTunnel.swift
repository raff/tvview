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
    func connect(region: String, conf: String) async throws {
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

        let status = await wait(for: [.connected, .disconnected, .invalid], on: m, timeout: 30)
        if status == .connected { return }
        throw TunnelError(await failureText(m, timedOut: status != .disconnected && status != .invalid))
    }

    /// Turns the VPN off, if it is on.
    func disconnect() async {
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
    private func failureText(_ m: NETunnelProviderManager, timedOut: Bool) async -> String {
        var parts: [String] = []
        if timedOut {
            parts.append("The VPN did not connect within 30 s.")
            m.connection.stopVPNTunnel()
        } else {
            parts.append("The VPN stopped while connecting.")
        }
        if let reason = await lastDisconnectError(m) { parts.append(reason) }
        if let log = await extensionLog(m), !log.isEmpty {
            parts.append("Tunnel log:\n" + log.split(separator: "\n").suffix(6).joined(separator: "\n"))
        }
        return parts.joined(separator: " ")
    }

    private func lastDisconnectError(_ m: NETunnelProviderManager) async -> String? {
        do {
            try await m.connection.fetchLastDisconnectError()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func extensionLog(_ m: NETunnelProviderManager) async -> String? {
        guard let session = m.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(Data([0])) { data in
                    cont.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                cont.resume(returning: nil)
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

struct TunnelError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
