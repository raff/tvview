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

From the repo root: `make test` (Go + Swift tests), `make swift-mac`, `make swift-ios`,
`make swift-run`. Or by hand:

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
- **iOS:** an iOS app cannot reach into iCloud Drive by itself, so the first time
  it shows the built-in channels with a **Choose folder…** prompt. Pick the same
  iCloud Drive `tvview` folder the Mac uses; the choice is remembered (a
  security-scoped bookmark) and the iPad then reads and saves the same
  `channels.yaml` and `wireguard/` as the Mac. "Choose Config Folder…" in the
  keyboard-shortcut menu changes it, and "Reload Configuration" (Shift-Cmd-R,
  both platforms) re-reads the file after an edit elsewhere. Until a folder is
  chosen, the app's Documents folder is searched, then the built-in default.
  `TVVIEW_CONFIG_FOLDER` sets the folder from the environment (both platforms),
  which is how the simulator was tested.

## How the page and the app talk

The sidebar and settings panel run in their own `WKContentWorld`, so the pages
they are injected into cannot see (or call) the bindings. `WebHost` defines each
`window.wvXxx()` in that world as a call to one reply-capable message handler,
which gives the same promise-returning functions go-webview's `Bind` did. Going
the other way, the app runs `window.wvToggleSidebar()` etc. in that world.
`hide.js` and `mediasession.js` stay in the page's world (`navigator.mediaSession`
must be the page's own).

## VPN

IT/UK-style channels (`region:` in the config) go through an **in-process**
WireGuard tunnel: `swift/vpn` is a small Go library (the same wireguard-go and
SOCKS5 code the Go app used before it moved to kernel interfaces) built as a
static library for macOS, iPhone/iPad and the simulator, and packaged as
`swift/build/TVVPN.xcframework` by `make swift-vpn` (`swift/vpn/build.sh`; a
few minutes, once). `VPNManager` starts a region's tunnel the first time a
channel needs it and points the web view's data store at its local SOCKS5 port;
nothing else on the device is routed. The status overlay, the `[VPN IT]` title
and the "add IT.conf to ..." message for pending files work as in the Go app.
`go run ./swift/vpn/cmd/tvvpncheck file.conf` brings a config up and prints its
exit address, to check a `.conf` without the app.

**Known limit:** it is a userspace TCP stack, and some CDNs drop those
connections. Seen with BBC iPlayer: through the UK tunnel the page's HTML
arrives (`www.bbc.co.uk`, 200 in about a second) but `static.files.bbci.co.uk`
and `ichef.bbci.co.uk`, which hold its scripts, styles and images, never answer
(`go run ./swift/vpn/cmd/tvvpncheck UK.conf https://static.files.bbci.co.uk/`
times out), so the page never finishes. After 25 s a message says so. This is
the reason the Go app switched to a real interface
(see the README, "Why a real interface"). RaiPlay and most other sites work.
The fix on a phone would be a Network Extension (system VPN, device-wide while
connected); not built. The arm64 simulator slice (Apple Silicon Macs) builds and
is tagged for the simulator, but has not been run (this was developed on an
Intel Mac).

## Status

Working (checked by running both targets): config loading and validation,
channel list in the sidebar, switching channels, last channel remembered, user
agent, per-channel hide selectors, sidebar toggle from the menu (Cmd-\\), the
Channels menu with Cmd-1…9, Reload / Back / Forward, window title.

Saving is checked by `../testdata/golden`, which the Go and Swift tests both run
(`GoldenTests.swift`, `golden_test.go`): same input and panel edit, same meaning out.

Settings panel: `wvGetConfig` / `wvSaveConfig` are implemented in `TVCore`
(`SettingsPanel`, `ConfigSave`: reconciling `vpn.tunnels`, `.bak`, atomic write)
and wired into `WebHost`. Saving re-registers the page scripts, so hide selectors
and media settings reach the next page load without a restart; window size and
VPN regions still need one. Checked end to end in the Mac app against a scratch
config (`TVVIEW_HOME=/some/dir` points the app at a different home, so a run can
not touch your real config).

Not done yet:

- The settings panel was not driven by hand on the iPad simulator (touch drag
  in particular), and the sidebar toggle is faint on a touch screen.
- The folder picker itself and the bookmark round trip were not exercised (the
  simulator run set the folder through the environment); iCloud files that are
  not yet downloaded rely on a file coordinator read, also untested.
- The fullscreen/PiP behaviour on a real device, the
  headphone seek behaviour on a real device, an app icon, signing for distribution.
