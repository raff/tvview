import Foundation
import TVCore
import WebKit

/// Owns the WKWebView and the bridge between it and the app.
///
/// The sidebar and settings panel run in their own content world: the page's
/// scripts share the DOM with them but cannot see `window.wvSaveConfig` or any
/// other function they define. That is what makes it safe to give them a
/// binding that writes the config, which the Go app (no content worlds) could
/// not do. hide.js and mediasession.js stay in the page's world, where
/// navigator.mediaSession is the page's own.
@MainActor
final class WebHost: NSObject {
    let webView: WKWebView
    weak var model: AppModel?

    private let world = WKContentWorld.world(name: "tvview")
    private let controller = WKUserContentController()

    /// Functions the injected scripts call; each becomes `window.<name>()`
    /// returning a promise, like go-webview's Bind.
    private static let bound = ["wvState", "wvSelect", "wvSetOpen", "wvGetConfig", "wvSaveConfig", "wvLog"]

    override init() {
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        #endif
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        #if os(iOS)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        #else
        webView.underPageBackgroundColor = .black
        #endif

        controller.addScriptMessageHandler(Bridge(self), contentWorld: world, name: "tv")
    }

    // MARK: setup

    /// Registers the user scripts for `cfg`. The static pieces mirror what
    /// main.go's inject() does with Init.
    func install(config cfg: Config) {
        installed = cfg
        webView.customUserAgent = cfg.userAgent

        let boot = Self.json(["channels": cfg.channels.map(Self.object), "media": Self.object(cfg.media)])
        // The screen's size and insets go in with the boot data, so the very first
        // layout of the sidebar already knows them (see __wvFitViewport).
        let safeJS = safe.isEmpty ? "" : " window.__wvSafe = \(Self.json(safe));"
        let bootJS = "window.__WV_BOOT = \(boot);" + safeJS
        let shim = """
        (function () {
          \(Self.json(Self.bound)).forEach(function (n) {
            window[n] = function () {
              return window.webkit.messageHandlers.tv.postMessage({ n: n, a: Array.prototype.slice.call(arguments) });
            };
          });
        })();
        """

        controller.removeAllUserScripts()
        // Sidebar world: boot data, the bridge, then the UI.
        add(bootJS, in: world, mainFrameOnly: true)
        add(shim, in: world, mainFrameOnly: true)
        add(Self.resource("sidebar"), in: world, mainFrameOnly: true)
        add(Self.resource("settings"), in: world, mainFrameOnly: true)
        // Page world: the two scripts that must see the page's own objects.
        add(bootJS, in: .page, mainFrameOnly: false)
        add(Self.resource("hide"), in: .page, mainFrameOnly: false)
        add(Self.resource("mediasession"), in: .page, mainFrameOnly: false)
    }

    private func add(_ source: String, in world: WKContentWorld, mainFrameOnly: Bool) {
        controller.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentStart,
            forMainFrameOnly: mainFrameOnly, in: world))
    }

    private static func resource(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            NSLog("tvview: missing resource %@.js", name)
            return ""
        }
        return text
    }

    // MARK: safe area

    private var safe: [String: Double] = [:]
    private var installed: Config?

    /// The insets of the screen the page is drawn under (camera cutout, corners,
    /// home indicator), which the page cannot see for itself. Remembered, and
    /// sent again after each page commits.
    func setSafeArea(top: Double, left: Double, bottom: Double, right: Double, width: Double, height: Double) {
        let now = ["top": top, "left": left, "bottom": bottom, "right": right, "width": width, "height": height]
        guard now != safe else { return }
        safe = now
        // Pages loaded from here on get it at document start; the one on screen gets it now.
        if let installed { install(config: installed) }
        sendSafeArea()
    }

    fileprivate func sendSafeArea() {
        guard !safe.isEmpty else { return }
        run("window.wvSafeArea && window.wvSafeArea(\(Self.json(safe)));")
    }

    // MARK: driving the page

    func load(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Runs script in the sidebar's world, which is where wvToggleSidebar and
    /// friends live.
    func run(_ js: String) {
        webView.evaluateJavaScript(js, in: nil, in: world) { _ in }
    }

    // MARK: JSON helpers

    static func object<T: Encodable>(_ v: T) -> Any {
        guard let data = try? JSONEncoder().encode(v),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return NSNull() }
        return obj
    }

    static func json(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8)
        else { return "null" }
        return s
    }

    // MARK: bridge calls

    fileprivate func handle(_ name: String, args: [Any]) -> (Any?, String?) {
        guard let model else { return (nil, "app is gone") }
        switch name {
        case "wvState":
            return ([
                "open": model.sidebarOpen,
                "current": model.current,
                "channels": model.cfg.channels.map(Self.object),
                "vpn": model.vpnSt as Any? ?? NSNull(),
            ] as [String: Any], nil)
        case "wvSelect":
            if let url = args.first as? String { model.select(url) }
            return (nil, nil)
        case "wvSetOpen":
            if let open = args.first as? Bool { model.setSidebarOpen(open) }
            return (nil, nil)
        case "wvLog":
            NSLog("tvview: page: %@", (args.first as? String) ?? "")
            return (nil, nil)
        case "wvGetConfig":
            return (SettingsPanel.view(of: model.cfg, defaultText: AppModel.defaultConfigText), nil)
        case "wvSaveConfig":
            guard let request = args.first as? String else { return (nil, "bad request") }
            let out = SettingsPanel.save(
                request: request, current: model.cfg, running: model.runningVPN,
                // install(config:) below re-registers the page scripts, so
                // hide selectors and media settings apply from the next page.
                liveScripts: true,
                // The manager reads the live config each time a tunnel is needed.
                liveVPN: true)
            if let fresh = out.config { model.apply(fresh) }
            return (out.response, nil)
        default:
            return (nil, "unknown call \(name)")
        }
    }
}

/// Weak-ish front for the message handler: the user content controller keeps
/// its handlers alive, so it must not own the host that owns it.
private final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var host: WebHost?
    init(_ host: WebHost) { self.host = host }

    @MainActor
    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let name = body["n"] as? String,
              let host
        else { return replyHandler(nil, "bad message") }
        let (result, error) = host.handle(name, args: body["a"] as? [Any] ?? [])
        replyHandler(result, error)
    }
}

extension WebHost: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        NSLog("tvview: loading %@", webView.url?.absoluteString ?? "(none)")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        NSLog("tvview: committed %@", webView.url?.absoluteString ?? "(none)")
        sendSafeArea()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("tvview: finished %@", webView.url?.absoluteString ?? "(none)")
        model?.pageFinished()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    /// A load that fails otherwise just leaves the old (or a blank) page up, which
    /// looks like a hang. Say so, except for the cancellations every redirect and
    /// quick channel switch causes.
    private func failed(_ webView: WKWebView, _ error: Error) {
        let e = error as NSError
        NSLog("tvview: load failed (%@ %ld): %@", e.domain, e.code, e.localizedDescription)
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return } // interrupted by a policy change (a download, a deep link)
        model?.pageFailed(e)
    }

    /// target=_blank and window.open would otherwise do nothing in a view with
    /// no tabs; show them in place.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}
