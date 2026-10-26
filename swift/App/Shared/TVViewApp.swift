import SwiftUI
import TVCore

@main
struct TVViewApp: App {
    @StateObject private var model = AppModel()

    init() {
        #if os(iOS)
        AudioSession.configure()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .commands { AppCommands(model: model) }
        #if os(macOS)
        .defaultSize(width: CGFloat(model.cfg.window.width), height: CGFloat(model.cfg.window.height))
        #endif
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            WebViewContainer(webView: model.host.webView)
            if let err = model.startupError {
                Text("Using built-in channels: \(err)")
                    .font(.footnote)
                    .padding(8)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding()
            }
        }
        .ignoresSafeArea()
        #if os(macOS)
        .navigationTitle(model.windowTitle)
        #else
        .statusBarHidden()
        #endif
    }
}

/// The menu bar on macOS, and the shortcut sheet on an iPad with a keyboard.
/// Same shortcuts as menu_darwin.go.
struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.openSettings() }.keyboardShortcut(",")
        }
        CommandGroup(after: .toolbar) {
            Button("Reload") { model.reload() }.keyboardShortcut("r")
            Divider()
            Button("Back") { model.back() }.keyboardShortcut(.leftArrow)
            Button("Forward") { model.forward() }.keyboardShortcut(.rightArrow)
            Divider()
            Button(model.sidebarOpen ? "Hide Sidebar" : "Show Sidebar") { model.toggleSidebar() }
                .keyboardShortcut("\\")
        }
        CommandMenu("Channels") {
            Button("Channel Up") { model.step(1) }.keyboardShortcut("]")
            Button("Channel Down") { model.step(-1) }.keyboardShortcut("[")
            Divider()
            ForEach(Array(model.cfg.channels.enumerated()), id: \.offset) { i, ch in
                if i < 9 {
                    Button(ch.title) { model.select(ch.url) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
                } else {
                    Button(ch.title) { model.select(ch.url) }
                }
            }
        }
    }
}
