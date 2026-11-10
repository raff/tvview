#if DEBUG
import AppKit
import WebKit

/// Debug builds only. With TVVIEW_DUMP_URL set, loads that page the way a search does (a
/// hidden view in the default data store, so with the installed app's logins), waits, and
/// writes what it rendered to TVVIEW_DUMP_DIR, then quits. For finding search_result selectors.
///
///   TVVIEW_DUMP_URL    page to load
///   TVVIEW_DUMP_DIR    output folder (default /tmp)
///   TVVIEW_DUMP_WAIT   seconds to wait after the load finishes (default 10)
///   TVVIEW_DUMP_PRE    optional JavaScript file injected at document start, before the page's scripts
///   TVVIEW_DUMP_JS     optional file of JavaScript; its result is written to result.txt
@MainActor
final class DebugDump: NSObject, WKNavigationDelegate {
    private static var current: DebugDump?
    private let view: WKWebView
    private let dir: String
    private let wait: Double
    private let js: String?

    static func runIfRequested(userAgent: String, beside: WKWebView) {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["TVVIEW_DUMP_URL"], let url = URL(string: s) else { return }
        // Wait for the window: a view in none is not rendered.
        guard let content = beside.window?.contentView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { runIfRequested(userAgent: userAgent, beside: beside) }
            return
        }
        let d = DebugDump(env: env, userAgent: userAgent)
        current = d
        content.addSubview(d.view)
        NSLog("tvview: dump loading %@", url.absoluteString)
        d.view.load(URLRequest(url: url))
    }

    private init(env: [String: String], userAgent: String) {
        dir = env["TVVIEW_DUMP_DIR"] ?? "/tmp"
        wait = Double(env["TVVIEW_DUMP_WAIT"] ?? "") ?? 10
        js = env["TVVIEW_DUMP_JS"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = .all
        view = WKWebView(frame: CGRect(x: -20000, y: 0, width: 1280, height: 800), configuration: config)
        view.customUserAgent = userAgent
        view.isInspectable = true
        // Runs before the page's own scripts, for hooks that must see its first calls.
        if let pre = env["TVVIEW_DUMP_PRE"].flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }) {
            view.configuration.userContentController.addUserScript(WKUserScript(source: pre, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        super.init()
        view.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in dump() }
    }

    /// Runs the script first (a click, say), waits again, then writes the page and the script's result.
    private func dump() {
        NSLog("tvview: dump of %@", view.url?.absoluteString ?? "?")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let js else { return write("") }
        view.evaluateJavaScript(js) { [self] result, error in
            let text = error.map { "ERROR: \($0)" } ?? "\(result ?? "nil")"
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { write(text) }
        }
    }

    private func write(_ result: String) {
        view.evaluateJavaScript("location.href + '\\n' + document.documentElement.outerHTML") { [self] html, _ in
            try? ((html as? String) ?? "").write(toFile: dir + "/dump.html", atomically: true, encoding: .utf8)
            if js != nil { try? result.write(toFile: dir + "/result.txt", atomically: true, encoding: .utf8) }
            NSLog("tvview: dump written to %@", dir)
            NSApp.terminate(nil)
        }
    }
}
#endif
