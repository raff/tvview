# tvview, Swift edition (macOS + iPad)

A SwiftUI app with a macOS and an iOS/iPadOS target, sharing one codebase. It
reuses the Go app's page scripts and default config **unchanged**: `sidebar.js`,
`settings.js`, `hide.js`, `mediasession.js` and `channels.yaml` are read from the
repo root and copied into the bundle at build time. See `../PORTING.md` for the
reasoning and `../SETTINGS.md` for the settings-panel design.

## Layout

| Path | What |
| --- | --- |
| `TVCore/` | SwiftPM package, no UI: config model, loading, validation (a port of `config.go`). `swift test` runs it. |
| `App/Shared/` | `AppModel` (live state), `WebHost` (the `WKWebView` and the page bridge), `TVViewApp` (scene, commands). |
| `App/macOS/`, `App/iOS/` | The per-platform bits: the `NSViewRepresentable`/`UIViewRepresentable` wrapper, the iOS audio session. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated, not committed. |

## Build and run

```sh
cd swift
xcodegen generate                       # after editing project.yml or adding files
(cd TVCore && swift test)               # config logic

# macOS
xcodebuild -project TVView.xcodeproj -scheme TVView-macOS -derivedDataPath build build
open "build/Build/Products/Debug/TV View.app"

# iPad simulator
xcodebuild -project TVView.xcodeproj -scheme TVView-iOS -derivedDataPath build \
  -destination 'platform=iOS Simulator,name=<an iPad>' CODE_SIGNING_ALLOWED=NO build
```

Or open `TVView.xcodeproj` in Xcode. To run on a real iPad, set
`DEVELOPMENT_TEAM` in `project.yml` and regenerate.

## Where the config comes from

- **macOS:** same order as the Go app, minus the working directory: iCloud Drive
  `tvview/channels.yaml`, then `~/.config/tvview/channels.yaml`, then the built-in
  default. The app is unsandboxed so it can read those (a Mac App Store build
  would need the sandbox and another location).
- **iOS:** the app's Documents folder (visible in Files), then the built-in
  default. Nothing seeds it yet; iCloud for iOS is not done.

## How the page and the app talk

The sidebar and settings panel run in their own `WKContentWorld`, so the pages
they are injected into cannot see (or call) the bindings. `WebHost` defines each
`window.wvXxx()` in that world as a call to one reply-capable message handler,
which gives the same promise-returning functions go-webview's `Bind` did. Going
the other way, the app runs `window.wvToggleSidebar()` etc. in that world.
`hide.js` and `mediasession.js` stay in the page's world (`navigator.mediaSession`
must be the page's own).

## Status

Working (checked by running both targets): config loading and validation,
channel list in the sidebar, switching channels, last channel remembered, user
agent, per-channel hide selectors, sidebar toggle from the menu (Cmd-\\), the
Channels menu with Cmd-1…9, Reload / Back / Forward, window title.

Settings panel: `wvGetConfig` / `wvSaveConfig` are implemented in `TVCore`
(`SettingsPanel`, `ConfigSave`: reconciling `vpn.tunnels`, `.bak`, atomic write)
and wired into `WebHost`. Saving re-registers the page scripts, so hide selectors
and media settings reach the next page load without a restart; window size and
VPN regions still need one. Checked end to end in the Mac app against a scratch
config (`TVVIEW_HOME=/some/dir` points the app at a different home, so a run can
not touch your real config).

Not done yet:

- VPN: regions load and validate, but no tunnel is raised (needs a
  `NEPacketTunnelProvider` extension; see `../PORTING.md`).
- The settings panel was not driven by hand on the iPad simulator (touch drag
  in particular), and the sidebar toggle is faint on a touch screen.
- iCloud config on iOS, the fullscreen/PiP behaviour on a real device, the
  headphone seek behaviour on a real device, an app icon, signing for distribution.
- Wiring `swift test` and a build of both targets into the Makefile.
- A golden-file test shared with the Go side (both apps are covered by mirrored
  tests, not by one fixture yet).
