import Combine
import Foundation
import SwiftUI
import TVCore
import WebKit

/// Everything the Go app's `app` struct held: the live config, which channel is
/// current, whether the sidebar is open, and the web view itself.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var cfg: Config
    @Published private(set) var current: String
    @Published private(set) var sidebarOpen = false
    /// Why the configured file could not be used, when the built-in defaults
    /// are showing instead.
    @Published private(set) var startupError: String?

    let host: WebHost
    private var hostChanges: AnyCancellable?
    let vpn = VPNManager()
    /// Last status shown by the page's VPN overlay, replayed to pages that load
    /// while a tunnel is still coming up (see wvState).
    @Published private(set) var vpnSt: [String: String]?
    /// The VPN setup the app started with, to tell whether a save needs a restart.
    let runningVPN: VPNConfig?

    /// iOS: asks the picker for the folder holding channels.yaml.
    @Published var showFolderPicker = false
    /// The prompt was closed without choosing. Not remembered: it comes back
    /// on the next launch, until a folder is chosen.
    @Published var folderPromptDismissed = false

    init() {
        #if os(iOS)
        ConfigFolder.restore()
        #endif
        var loaded: Config
        var failure: String?
        do {
            loaded = try Config.load(defaultText: AppModel.defaultConfigText)
        } catch {
            loaded = (try? Config.parse(AppModel.defaultConfigText, path: nil)) ?? Config()
            failure = error.localizedDescription
        }
        cfg = loaded
        runningVPN = loaded.vpn
        startupError = failure

        let last = UserDefaults.standard.string(forKey: "lastChannel") ?? ""
        current = loaded.channels.contains { $0.url == last } ? last : loaded.channels[0].url

        host = WebHost()
        host.model = self
        // The web view can be replaced, and the views showing it follow this model.
        hostChanges = host.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        host.startWatchdog()
        #if os(iOS) && !targetEnvironment(simulator)
        // The system VPN belongs to iOS, not to this app, so see to it ourselves: drop it when
        // the app is terminated, and bring it back when the app returns after the extension
        // gave it up (it does after a minute without hearing from us).
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.vpn.stopSystemVPNNow() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeVPN() }
        }
        #endif
        host.install(config: loaded)
        // A channel that needs a tunnel must not be fetched before there is one:
        // about:blank gives the status overlay a document to appear in, and keeps
        // the site from ever seeing the unrouted address.
        // With the system VPN, every launch goes through enter(): a VPN left up by an earlier
        // run must be dropped (or kept) to match the channel before anything loads.
        if regionFor(current).isEmpty && !VPNManager.usesSystemVPN {
            host.load(current)
        } else {
            host.load("about:blank")
            Task { await enter(current) }
        }
    }

    static var defaultConfigText: String {
        guard let url = Bundle.main.url(forResource: "channels", withExtension: "yaml"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "channels:\n  - {title: PBS, url: \"https://www.pbs.org\"}\n" }
        return text
    }

    // MARK: channels

    func select(_ url: String) {
        current = url
        UserDefaults.standard.set(url, forKey: "lastChannel")
        if vpn.current == regionFor(url) {
            vpnSt = nil // a stale error must not follow us to the new page
            host.load(url)
        } else {
            Task { await enter(url) }
        }
    }

    func regionFor(_ url: String) -> String {
        cfg.channels.first { $0.url == url }?.region ?? ""
    }

    /// Puts the right tunnel up and then goes to `url`, narrating the wait into
    /// the page it is leaving. Port of enterChannel in main.go.
    private func enter(_ url: String) async {
        let region = regionFor(url)
        NSLog("tvview: switching to %@ (region %@)", url, region.isEmpty ? "none" : region)
        let began = Date()
        showVPN("working", region.isEmpty ? "Disconnecting…" : "Connecting to \(region)…")
        do {
            try await vpn.ensure(region, config: cfg, store: host.webView.configuration.websiteDataStore)
            NSLog("tvview: tunnel for %@ ready in %.1fs", region.isEmpty ? "none" : region, Date().timeIntervalSince(began))
        } catch {
            NSLog("tvview: tunnel for %@ failed after %.1fs: %@", region, Date().timeIntervalSince(began), error.localizedDescription)
            // The user may have picked something else while this negotiated; that
            // switch owns the outcome now. Otherwise stay put: loading the
            // channel anyway would show a geo-block that looks like the site's fault.
            if current == url { showVPN("error", error.localizedDescription) }
            return
        }
        objectWillChange.send() // the window title shows which region is up
        guard current == url else { return }
        // Keep the spinner through the gap until the new page commits.
        showVPN("working", "Loading…")
        vpnSt = nil
        host.load(url)
        if !region.isEmpty { watchForStall(url, region: region) }
    }

    /// Some CDNs (BBC iPlayer's) silently drop connections from this tunnel's
    /// userspace TCP stack, so a page's HTML arrives and its scripts and images
    /// never do: nothing fails, it just never finishes. After a while, say so
    /// rather than leave a page that looks hung. Cleared if the load does finish.
    private func watchForStall(_ url: String, region: String) {
        stallHint = false
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.current == url, self.vpn.current == region, self.host.webView.isLoading else { return }
            self.stallHint = true
            self.showVPN("error", "Still loading after 25 s through the \(region) tunnel. Some sites (BBC iPlayer) block this kind of tunnel and their pages never finish.")
        }
    }

    private var stallHint = false

    /// The page finished loading: take down a stall message if one was showing.
    func pageFinished() {
        // A status sent while the page was being replaced can be lost; say it again now that
        // there is a page to show it.
        if let st = vpnSt, !stallHint {
            host.run("window.wvVPN && window.wvVPN(\(WebHost.json(st)));")
        }
        guard stallHint else { return }
        stallHint = false
        showVPN("done", "")
    }

    #if os(iOS) && !targetEnvironment(simulator)
    /// Back in front: if this channel needs a VPN and it has dropped, bring it back and reload.
    private func resumeVPN() {
        guard VPNManager.usesSystemVPN else { return }
        let url = current, region = regionFor(url)
        guard !region.isEmpty else { return }
        Task { [weak self] in
            guard let self, await !self.vpn.systemVPNIsUp(for: region) else { return }
            await self.enter(url)
        }
    }
    #endif

    /// Takes the status message down, for the native bar's Dismiss button.
    func dismissStatus() {
        showVPN("done", "")
        vpnSt = nil
    }

    /// A page failed to load: show why in the status overlay instead of leaving a
    /// blank or stale page.
    func pageFailed(_ error: NSError) {
        var text = "The page could not be loaded: \(error.localizedDescription)"
        if !vpn.current.isEmpty { text += " (through the \(vpn.current) tunnel)" }
        showVPN("error", text)
    }

    private func showVPN(_ state: String, _ text: String) {
        NSLog("tvview: overlay %@: %@", state, text)
        vpnSt = ["state": state, "text": text]
        host.run("window.wvVPN && window.wvVPN(\(WebHost.json(vpnSt!)));")
    }

    /// Next (delta 1) or previous (-1) channel, wrapping around the ends.
    func step(_ delta: Int) {
        let list = cfg.channels
        let i = list.firstIndex { $0.url == current } ?? 0
        select(list[(i + delta + list.count) % list.count].url)
    }

    /// Reads the config again from wherever it lives now: after choosing a
    /// folder, or after the file was edited elsewhere.
    func reloadConfig() {
        do {
            let fresh = try Config.load(defaultText: AppModel.defaultConfigText)
            startupError = nil
            apply(fresh)
            if !fresh.channels.contains(where: { $0.url == current }) { select(fresh.channels[0].url) }
            host.run("window.wvConfigChanged && window.wvConfigChanged();")
        } catch {
            startupError = error.localizedDescription
        }
    }

    /// True while the built-in channels are showing because no config file exists.
    var usingBuiltIn: Bool { cfg.path == nil }

    #if os(iOS)
    func configFolderChosen(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                try ConfigFolder.choose(url)
                reloadConfig()
            } catch {
                startupError = "Could not use that folder: \(error.localizedDescription)"
            }
        case .failure(let error):
            startupError = error.localizedDescription
        }
    }
    #endif

    /// A save went through: take the new config. Page scripts are registered
    /// again, so hide selectors and media settings reach the next page load; the
    /// user agent applies from the next load too. The channel list is read live
    /// by the sidebar and the Channels menu.
    func apply(_ fresh: Config) {
        cfg = fresh
        host.install(config: fresh)
    }

    func setSidebarOpen(_ open: Bool) { sidebarOpen = open }

    var windowTitle: String {
        guard let ch = cfg.channels.first(where: { $0.url == current }) else { return cfg.window.title }
        var title = cfg.window.title + " — " + ch.title
        if !vpn.current.isEmpty { title += "  [VPN \(vpn.current)]" }
        return title
    }

    // MARK: quitting (macOS)

    /// Shown for a moment after a first Cmd-Q.
    @Published private(set) var quitPromptVisible = false
    private var quitArmedAt: Date?

    /// Chrome's asymmetry, as in the Go app: choosing Quit from the menu is a
    /// deliberate act and quits at once, while Cmd-Q, which is easy to hit while
    /// reaching for Cmd-W or Tab, has to be pressed twice. The two are told apart
    /// by the event that triggered the command: a key equivalent leaves a key-down
    /// as the current event, a click leaves a mouse event.
    func requestQuit() {
        #if os(macOS)
        let fromKeyboard = NSApp.currentEvent?.type == .keyDown
        if !fromKeyboard || (quitArmedAt.map { Date().timeIntervalSince($0) <= 2.0 } ?? false) {
            NSApp.terminate(nil)
            return
        }
        quitArmedAt = Date()
        quitPromptVisible = true
        Task { [weak self] in
            // Outlives the arming window a little, so the prompt never vanishes
            // while a second press would still count.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.quitPromptVisible = false
        }
        #endif
    }

    // MARK: menu actions, reaching the page

    func toggleSidebar() { host.run("window.wvToggleSidebar && window.wvToggleSidebar();") }
    func openSettings() { host.run("window.wvOpenSettings && window.wvOpenSettings();") }
    func reload() {
        if host.unresponsive { resetPage() } else { host.webView.reload() }
    }

    /// Replaces the web view, ending a frozen page's process, and loads the
    /// current channel into the new one.
    func resetPage() {
        host.reset()
        vpnSt = nil
        host.load(current)
        // A reset lands on the same page, which may block again: watch it as a
        // channel switch does, or the person is left on a blank page with no word.
        let region = regionFor(current)
        if !region.isEmpty { watchForStall(current, region: region) }
    }
    func back() { host.webView.goBack() }
    func forward() { host.webView.goForward() }
}
