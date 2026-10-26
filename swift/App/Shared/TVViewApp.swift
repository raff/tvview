import SwiftUI
import TVCore
import UniformTypeIdentifiers

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
        GeometryReader { geo in
            content
            #if os(iOS)
                .onAppear { push(geo.safeAreaInsets, geo.size) }
                .onChange(of: geo.safeAreaInsets) { _, v in push(v, geo.size) }
                .onChange(of: geo.size) { _, v in push(geo.safeAreaInsets, v) }
            #endif
        }
        #if os(macOS)
        .navigationTitle(model.windowTitle)
        #else
        .statusBarHidden()
        .fileImporter(isPresented: $model.showFolderPicker, allowedContentTypes: [.folder]) {
            model.configFolderChosen($0)
        }
        #endif
    }

    #if os(iOS)
    /// The page extends under the camera cutout and corners, so tell it where
    /// they are and let the sidebar keep its controls out of them.
    private func push(_ i: EdgeInsets, _ size: CGSize) {
        model.host.setSafeArea(
            top: i.top, left: i.leading, bottom: i.bottom, right: i.trailing,
            width: size.width + i.leading + i.trailing, height: size.height + i.top + i.bottom)
    }
    #endif

    private var content: some View {
        ZStack(alignment: .bottom) {
            Color.black
            WebViewContainer(webView: model.host.webView)
            VStack(spacing: 8) {
                #if os(iOS)
                if model.usingBuiltIn && !model.folderPromptDismissed { folderPrompt }
                #endif
                if let err = model.startupError {
                    Text("Using built-in channels: \(err)")
                        .font(.footnote)
                        .padding(8)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
            }
            .padding()
        }
        .ignoresSafeArea()
    }
}

#if os(iOS)
extension ContentView {
    /// Shown while no config file is in use: the way to point the app at the
    /// iCloud Drive `tvview` folder the Mac shares.
    var folderPrompt: some View {
        VStack(spacing: 6) {
            Text("These are the built-in channels. To use your own, choose the tvview folder (the one with channels.yaml, normally in iCloud Drive).")
                .font(.footnote)
                .multilineTextAlignment(.center)
            Button("Choose folder…") { model.showFolderPicker = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Button {
                model.folderPromptDismissed = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .padding(6)
            }
            .accessibilityLabel("Dismiss")
        }
    }
}
#endif

/// The menu bar on macOS, and the shortcut sheet on an iPad with a keyboard.
/// Same shortcuts as menu_darwin.go.
struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.openSettings() }.keyboardShortcut(",")
        }
        CommandGroup(after: .importExport) {
            Button("Reload Configuration") { model.reloadConfig() }.keyboardShortcut("r", modifiers: [.command, .shift])
            #if os(iOS)
            Button("Choose Config Folder…") { model.showFolderPicker = true }
            #endif
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
