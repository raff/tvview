import Foundation
import TVCore
import WebKit

/// Searches every channel that has a search_url and collects the results.
///
/// A site's results only exist once its own JavaScript has run with the viewer's
/// cookies, so each one is read from a hidden web view sharing the logins of the
/// visible one. All of a data store's views share one proxy, so a channel is read
/// only when its region is the VPN that is up; any other gets a link to its results
/// page, and following that link brings up its tunnel as choosing the channel does.
///
/// Held here rather than in the page: the sidebar is rebuilt on every navigation.
@MainActor
final class SearchManager {
    struct Item {
        let title, url, image: String
    }

    private enum Status: String {
        case searching, done, link
    }

    private struct Group {
        let channel: Channel
        let page: String
        var status: Status
        var items: [Item] = []
    }

    /// Each hidden view is a whole page load, and a video may be playing.
    private static let parallel = 3

    weak var model: AppModel?
    private var query = ""
    private var groups: [Group] = []
    private var queue: [Int] = []
    private var active: [Int: Scrape] = [:]

    /// What the sidebar shows, or NSNull when no search is up.
    var state: Any {
        guard !query.isEmpty else { return NSNull() }
        return [
            "query": query,
            "groups": groups.map { g -> [String: Any] in
                [
                    "title": g.channel.title,
                    "url": g.channel.url,
                    "region": g.channel.region,
                    "page": g.page,
                    "status": g.status.rawValue,
                    "items": g.items.map { ["title": $0.title, "url": $0.url, "image": $0.image] },
                ]
            },
        ] as [String: Any]
    }

    func start(_ text: String) {
        guard let model else { return }
        abandon()
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            groups = []
            publish()
            return
        }
        let up = model.vpn.current
        groups = model.cfg.channels.compactMap { ch in
            guard let page = ch.searchPage(for: query) else { return nil }
            let readable = !ch.searchResult.isEmpty && ch.region == up
            return Group(channel: ch, page: page, status: readable ? .searching : .link)
        }
        queue = groups.indices.filter { groups[$0].status == .searching }
        NSLog("tvview: searching %d channels, reading %d", groups.count, queue.count)
        publish()
        pump()
    }

    /// Ends the hidden loads and keeps what they found; what had not finished becomes a
    /// link. Called before anything that moves the page or the VPN, since a tunnel
    /// change would reroute the hidden views too.
    func stop() {
        guard !active.isEmpty || !queue.isEmpty else { return }
        abandon()
        for i in groups.indices where groups[i].status == .searching { groups[i].status = .link }
        publish()
    }

    func clear() {
        abandon()
        query = ""
        groups = []
        publish()
    }

    private func abandon() {
        queue = []
        active.values.forEach { $0.cancel() }
        active = [:]
    }

    private func pump() {
        guard let model else { return }
        while active.count < Self.parallel, !queue.isEmpty {
            let i = queue.removeFirst()
            let ch = groups[i].channel
            guard let url = URL(string: groups[i].page) else {
                groups[i].status = .link
                continue
            }
            let scrape = Scrape(
                url: url, selector: ch.searchResult,
                userAgent: ch.userAgent.isEmpty ? model.cfg.userAgent : ch.userAgent,
                beside: model.host.webView
            ) { [weak self] scrape, items in
                guard let self, self.active[i] === scrape else { return }
                self.active[i] = nil
                self.groups[i].items = items
                self.groups[i].status = items.isEmpty ? .link : .done
                self.publish()
                self.pump()
            }
            active[i] = scrape
            scrape.begin()
        }
        // A bad URL above can be the last thing in the queue.
        if active.isEmpty { publish() }
    }

    private func publish() {
        model?.host.run("window.wvSearchUpdate && window.wvSearchUpdate(\(WebHost.json(state)));")
    }
}

/// One channel's hidden web view: loads the search page, waits for the results to
/// stop changing, hands them over once and takes itself apart.
@MainActor
private final class Scrape: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private static let world = WKContentWorld.world(name: "tvview-search")
    /// Longer than the script's own limit, for a page that never gets as far as running it.
    private static let timeout: UInt64 = 20_000_000_000

    private let view: WKWebView
    private let url: URL
    private weak var beside: WKWebView?
    private var onDone: ((Scrape, [SearchManager.Item]) -> Void)?
    private var timer: Task<Void, Never>?

    init(url: URL, selector: String, userAgent: String, beside: WKWebView, onDone: @escaping (Scrape, [SearchManager.Item]) -> Void) {
        self.url = url
        self.beside = beside
        self.onDone = onDone
        let config = WKWebViewConfiguration() // the default data store: the same logins
        config.mediaTypesRequiringUserActionForPlayback = .all // nothing here may start to play
        let controller = config.userContentController
        // Wider than a phone on purpose: sites keep the desktop result grid.
        view = WKWebView(frame: CGRect(x: -20000, y: 0, width: 1280, height: 800), configuration: config)
        view.customUserAgent = userAgent
        super.init()
        controller.addUserScript(WKUserScript(
            source: "(function (selector) {\(Self.extract)})(\(WebHost.json([selector]))[0]);",
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        controller.add(self, contentWorld: Self.world, name: "search")
        view.navigationDelegate = self
    }

    func begin() {
        // In a window, though out of its bounds: WebKit stops rendering a view that is
        // in none, and these pages only build their results when they render.
        #if os(macOS)
        beside?.window?.contentView?.addSubview(view)
        #else
        beside?.window?.addSubview(view)
        #endif
        view.load(URLRequest(url: url))
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.timeout)
            guard !Task.isCancelled else { return }
            self?.finish([])
        }
    }

    func cancel() {
        onDone = nil
        tearDown()
    }

    private func finish(_ items: [SearchManager.Item]) {
        let done = onDone
        onDone = nil
        tearDown()
        done?(self, items)
    }

    private func tearDown() {
        timer?.cancel()
        view.navigationDelegate = nil
        view.stopLoading()
        // The controller holds this handler, which holds the view, which holds the controller.
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.configuration.userContentController.removeAllUserScripts()
        view.removeFromSuperview()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let found = message.body as? [[String: String]] ?? []
        // From a site's page, so it is checked here as well as where it is shown.
        finish(found.compactMap { r in
            guard let title = r["title"], !title.isEmpty, let link = r["url"], Self.isWeb(link) else { return nil }
            let image = r["image"] ?? ""
            return SearchManager.Item(title: title, url: link, image: Self.isWeb(image) ? image : "")
        })
    }

    private static func isWeb(_ s: String) -> Bool {
        let scheme = URL(string: s)?.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        let e = error as NSError
        // The cancellations a redirect causes; the page that replaced it carries on.
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return }
        NSLog("tvview: search of %@ failed: %@", url.absoluteString, e.localizedDescription)
        finish([])
    }

    /// The body of a function taking the channel's selector. A selector can match the
    /// link or a card around it. Links are taken with a title only, so the image-only
    /// link a card often has beside its text link gives way to the one with words.
    private static let extract = #"""
    var LIMIT = 12, TICK = 500, SETTLED = 3, MAX_TICKS = 24;

    function clean(s) { return (s || "").replace(/\s+/g, " ").trim().slice(0, 140); }

    function linkOf(el) {
      return el.closest("a[href]") || el.querySelector("a[href]");
    }

    function collect() {
      var out = [], seen = {};
      var els = document.querySelectorAll(selector);
      for (var i = 0; i < els.length && out.length < LIMIT; i++) {
        var a = linkOf(els[i]);
        if (!a || seen[a.href]) continue;
        var img = a.querySelector("img") || els[i].querySelector("img");
        var title = clean(a.getAttribute("title")) || clean(a.textContent) ||
          clean(img && img.alt) || clean(a.getAttribute("aria-label"));
        if (!title) continue;
        seen[a.href] = true;
        out.push({ title: title, url: a.href, image: img ? img.currentSrc || img.src || "" : "" });
      }
      return out;
    }

    function post(items) { window.webkit.messageHandlers.search.postMessage(items); }

    var last = -1, same = 0, ticks = 0;
    var timer = setInterval(function () {
      var n;
      try {
        n = document.querySelectorAll(selector).length;
      } catch (e) {
        clearInterval(timer); // an invalid selector
        post([]);
        return;
      }
      same = n > 0 && n === last ? same + 1 : 0;
      last = n;
      if (same >= SETTLED || ++ticks >= MAX_TICKS) {
        clearInterval(timer);
        post(collect());
      }
    }, TICK);
    """#
}
