import SwiftUI
import WebKit

/// The startup animation, drawn by splash.js in a web view of its own, on top of
/// the channel's.
///
/// splash.js is the same script the Go app injects into the channel's page. Here
/// it cannot be: an injected script only runs once the page's document exists,
/// and a slow site (Netflix: seconds to its first byte) would delay the start of
/// the animation by that long. A separate web view has its own document at once,
/// and the channel loads underneath it in parallel.
@MainActor
final class SplashModel: ObservableObject {
    /// False once the animation has finished or been skipped.
    @Published var playing = !ProcessInfo.processInfo.arguments.contains("-nosplash")

    let webView: WKWebView

    init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setBackground(.black)
        guard playing else { return }

        // splash.js calls this when it ends, however it ends.
        let handler = Done { [weak self] in self?.playing = false }
        controller.add(handler, name: "splashDone")

        guard let url = Bundle.main.url(forResource: "splash", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8)
        else {
            NSLog("tvview: missing resource splash.js")
            playing = false
            return
        }
        // The script only plays when boot.splash is recent; the page is new, so now.
        let html = "<!doctype html><html><body style=\"margin:0;background:#000\"><script>"
            + "window.__WV_BOOT = { splash: Date.now() };\n" + js + "</script></body></html>"
        webView.loadHTMLString(html, baseURL: nil)
    }

    private final class Done: NSObject, WKScriptMessageHandler {
        let fire: @MainActor () -> Void
        init(_ fire: @escaping @MainActor () -> Void) { self.fire = fire }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            MainActor.assumeIsolated { fire() }
        }
    }
}

private extension WKWebView {
    func setBackground(_ color: PlatformColor) {
        #if os(iOS)
        isOpaque = false
        backgroundColor = color
        scrollView.backgroundColor = color
        scrollView.isScrollEnabled = false
        #else
        setValue(false, forKey: "drawsBackground")
        #endif
    }
}

#if os(iOS)
private typealias PlatformColor = UIColor
#else
private typealias PlatformColor = NSColor
#endif

struct SplashOverlay: View {
    @ObservedObject var splash: SplashModel

    var body: some View {
        if splash.playing {
            WebViewContainer(webView: splash.webView)
                .ignoresSafeArea()
        }
    }
}
