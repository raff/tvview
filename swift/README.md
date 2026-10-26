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

## VPN: where we are and what is next

The two platforms get different tunnels, for different reasons.

### macOS: the Go app's kernel tunnel (done)

IT/UK-style channels (`region:` in the config) get a WireGuard tunnel on a real
kernel `utun` interface raised by `vpnhelper`, exactly as the Go app does, and the
web view's sockets are bound to that interface through a local SOCKS5 proxy
(`IP_BOUND_IF`). Nothing is routed system-wide, so a company VPN that is already up
is left alone, and BBC iPlayer's CDN accepts the real TCP stack (it renders fully;
the userspace tunnel never got past the page's HTML).

- The code is **shared with the Go app**: `internal/kernelvpn` (moved out of the Go
  app's `package main`; `vpn_kernel_darwin.go` is now a thin wrapper and the Go app's
  tests still pass). `swift/vpn/export` calls it on macOS (`backend_macos.go`).
- `vpnhelper` (built by `swift/vpn/build.sh` into `swift/build/vpnhelper`, universal) is
  copied into `TV View.app/Contents/MacOS/` and signed with the app (a `copyFiles`
  entry in `project.yml`). The library finds it beside `os.Executable()`.
- The first start of each region per launch shows macOS's administrator password
  dialog (or none, with the Go app's `sudoers.d` rule; see below). `VPNManager`
  waits up to 120 s on macOS. Cancelling the dialog now fails at once with a message
  (the Go app used to wait five minutes), a fix in `runHelper`.
- Interfaces exist only while the app runs (13 `utun` with two regions up, 11 after
  quit).
- `TVVPN_USERSPACE=1` in the environment makes the macOS library use the in-process
  tunnel instead, to compare the two.
- `scripts/install-vpn-helper.sh` (passwordless sudo for the helper) takes the app
  path as an argument; for this app it would be `"/Applications/TV View.app"`.
  Untested with the Swift bundle.

**Still to check by hand:** RaiPlay *movies and series* (the report that led here:
live channels played, on-demand did not, through the userspace tunnel). The page,
BBC iPlayer and RaiPlay's front page all load; playback of on-demand video through
the kernel tunnel has not been tried.

### iOS/iPadOS: today an in-process tunnel; next a Network Extension

Today (built, working on a phone): the same `swift/vpn` library, built for iOS, runs
the tunnel **in-process** as a userspace WireGuard device with a local SOCKS5 proxy
(`swift/vpn/tunnel`, the code the Go app used before kernel interfaces), packaged
as `swift/build/TVVPN.xcframework` by `make swift-vpn` (`swift/vpn/build.sh`; `make
swift-mac`/`swift-ios` build it if missing). `VPNManager` starts a region's tunnel
the first time a channel needs it (20 s limit on iOS, one start per region) and points
the web view's data store at the proxy; nothing else on the device is routed. The
status overlay, `[VPN IT]` title, the 25 s "page may be blocked" message and the
"add IT.conf to ..." message for pending files work as in the Go app, and a native
bar (channel menu + Dismiss) appears whenever the overlay shows an error, so a stuck
page can always be left. A tunnel file written as
`~/Library/Mobile Documents/.../IT.conf` is found by name in the `wireguard/` folder
beside the config when that path does not exist (iOS, where `~` is the app's
sandbox). `go run ./swift/vpn/cmd/tvvpncheck file.conf [url]` brings a config up
in-process and fetches a URL through it (UK exits in London, IT in Milan).

**Known limit of that tunnel:** some CDNs drop a userspace TCP stack. BBC iPlayer
through the UK tunnel: `www.bbc.co.uk` answers in about a second, but
`static.files.bbci.co.uk` and `ichef.bbci.co.uk` (its scripts, styles, images) never
do (`tvvpncheck UK.conf https://static.files.bbci.co.uk/` times out), so the page
never finishes. RaiPlay's front page works, checked on a phone.

**Decided:** a global VPN while the app is in use is fine on iOS, so BBC (and
on-demand RaiPlay, if it needs it) gets a Network Extension, built into the app.

### Next, in order

1. **Check the sidebar fix on the phone** (commit `31883b1`): BBC iPlayer used to squash
   the sidebar into a sliver; Amazon and PBS must still look right. The page logs
   `viewport scaled/plain ...` (see the log recipe below). Also install the current
   build on the phone (it has not been reinstalled since the macOS work; the iOS
   behaviour is unchanged).
2. **Try RaiPlay movies and series on the Mac** (above). If they still fail through
   the kernel tunnel, it is not the TCP stack, and the Go app is the reference.
3. **iOS: Network Extension.**
   - Portal: App ID `io.github.raff.tvview.swift.tunnel` with the Network Extensions
     capability, and the same capability on the app's ID (`io.github.raff.tvview.swift`,
     already registered). Xcode's automatic signing (`-allowProvisioningUpdates`, team
     `EDG4R37566`) can enable it.
   - New target `TVView-Tunnel`: an app extension whose principal class is a
     `NEPacketTunnelProvider`, entitlement `com.apple.developer.networking.networkextension`
     = `packet-tunnel-provider` on both app and extension, embedded in the iOS app. Not
     testable in the simulator; needs a device.
   - The Go library gets a second entry point that runs wireguard-go on the extension's
     tunnel file descriptor (as WireGuardKit does) instead of making a netstack; Swift
     builds `NEPacketTunnelNetworkSettings` (addresses, DNS, MTU, routes) from the
     `.conf` (`wireproxy.CreateIPCRequest` in `internal/kernelvpn` already parses the
     fields it needs; TVCore parses the file's structure).
   - App side: `NETunnelProviderManager` to save, load, start and stop; a channel with a
     region turns the right tunnel on and waits for `.connected` (one tunnel at a time, so
     a region switch reconfigures); the same overlay messages; a clear message when the
     user declines the one-time "add VPN configuration" prompt.
   - Decide then whether iOS keeps the in-process tunnel as a fallback.
4. Smaller items under *Status*.

### Working notes (learned the hard way)

- Installing or relaunching with `devicectl` **stops the app on the phone**, and
  killing a `devicectl ... --console` session closes it too. Tell the user first.
  The phone must be unlocked for a launch (`BSErrorCodeDescription = Locked`
  otherwise); the install still happens.
- Phone log: `xcrun devicectl device process launch --console --terminate-existing
  --device <id> io.github.raff.tvview.swift > log` (`NSLog` and the Go library's
  stderr both appear). Device list: `xcrun devicectl list devices`.
- Device build: `xcodebuild ... -destination 'id=<udid>' -allowProvisioningUpdates build`
  (udid from `-showdestinations`; it differs from the devicectl id).
- This was developed on an **Intel** Mac: the iOS simulator slice that actually
  ran is x86_64. The arm64 simulator slice of `TVVPN.xcframework` builds and is
  tagged `IOSSIMULATOR` but was never run.
- Try the Mac app without touching the real config: `TVVIEW_HOME=/scratch/dir`.
  Drive it with menu clicks (System Events), not window coordinates: clicking
  inside a `WKWebView` that way was unreliable. Screenshot a single window with
  `screencapture -l <windowid>`.
- Go `c-archive` for iOS needs the matching SDK's clang as `CC` (see
  `swift/vpn/build.sh`); all five slices take about 70 s from cold, 15 s cached.
- Testing the macOS tunnel needs a person: the administrator dialog cannot be driven.
  Pick channels from the Channels menu with System Events, then watch `ifconfig -l`.

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
and media settings reach the next page load without a restart, and VPN regions
are read from the live config, so only a window size change needs one. Checked end to end in the Mac app against a scratch
config (`TVVIEW_HOME=/some/dir` points the app at a different home, so a run can
not touch your real config).

Not done yet (besides the VPN steps above):

- The settings panel was not driven by hand on the iPad simulator (touch drag
  in particular), and the sidebar toggle is faint on a touch screen.
- The folder picker itself and the bookmark round trip were not exercised (the
  simulator run set the folder through the environment); iCloud files that are
  not yet downloaded rely on a file coordinator read, also untested.
- Fullscreen/PiP, background audio and the headphone seek on a real device were not
  checked. Distribution (TestFlight/App Store, notarized Mac build) is not set up;
  the team has a Developer ID Application certificate.
- The app icon is the Go app's, as a placeholder.
