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
        host.install(config: loaded)
        host.load(current)
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
        host.load(url)
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
        return cfg.window.title + " — " + ch.title
    }

    // MARK: menu actions, reaching the page

    func toggleSidebar() { host.run("window.wvToggleSidebar && window.wvToggleSidebar();") }
    func openSettings() { host.run("window.wvOpenSettings && window.wvOpenSettings();") }
    func reload() { host.webView.reload() }
    func back() { host.webView.goBack() }
    func forward() { host.webView.goForward() }
}
