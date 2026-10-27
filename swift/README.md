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

### iOS/iPadOS: the system VPN (done; the full login-and-play flow is not yet checked)

On a **device**, a region channel connects a **system VPN**: `TVView-Tunnel`
(`App/Tunnel`) is a `NEPacketTunnelProvider` app extension, with its own App ID
(`io.github.raff.tvview.swift.tunnel`; see *One-time Apple Developer setup* below) and
the packet-tunnel Network Extensions entitlement on both the extension and the app.
Because it hands WireGuard the real network stack's packets, the CDNs that drop a
userspace TCP stack (BBC iPlayer) accept it: the BBC and RaiPlay pages load past the
region check on a phone, and Settings shows the VPN connected when a region channel is open.

How it fits together:
- `SystemTunnel` (`App/iOS`) owns one VPN configuration, "TV View": it saves it with the
  WireGuard `.conf` **text** in `providerConfiguration` (the extension is sandboxed apart
  from the app and cannot read the iCloud folder), starts it, waits for "connected" (30 s)
  and says why it did not. One tunnel at a time: a different region replaces the running
  one; a channel with no region turns it off. `VPNManager` picks it on a device
  (`usesSystemVPN`); the simulator keeps the in-process tunnel (it cannot run a packet
  tunnel) and macOS keeps `vpnhelper`.
- The extension (`PacketTunnelProvider`): parses the `.conf` (`TVCore.WireGuardConf`: addresses,
  DNS, MTU, endpoint, routes), calls `TVVPNTunnelPrepare` (Go: parse and resolve the endpoint
  *before* any settings are applied), applies `NEPacketTunnelNetworkSettings`, then
  `TVVPNTunnelStart` (Go: finds the utun descriptor, `wireguard-go` on it). IPv4-only providers
  that allow `::/0` get a private IPv6 address on the interface, so IPv6 enters the tunnel and
  fails fast instead of leaking around it.
- Debugging an extension has no console: the extension keeps a step log (its own `note()`
  lines plus the Go library's ring buffer) and the app asks for it by provider message while
  connecting, appending the last lines to any failure. The steps also go to the system
  log (subsystem `io.github.raff.tvview.tunnel`; reading a phone's log from the Mac needs
  `sudo log collect --device`).

Behaviour to know:
- **Device-wide while it is up.** Everything on the phone goes through it, not only this app.
  Switching to a channel with no region turns it off. The app hides the status bar, so look in
  Settings (or Control Center) for the VPN, not the status-bar badge.
- **It does not outlive the app.** iOS gives an app no reliable "being quit" moment (a swiped
  or killed app is usually suspended and told nothing), and the system VPN belongs to iOS. So
  the app sends the extension a one-byte heartbeat every 15 s while its process runs, and the
  extension stops the tunnel after 60 s of silence (the dead man's switch in
  `PacketTunnelProvider`). A killed, crashed or suspended app therefore drops the VPN within
  about a minute; a brief trip to another app does not. `willTerminate` also stops it at once
  when the app gets to see it. Coming back to the app after the VPN dropped reconnects it and
  reloads the page. Audio playing in the background keeps the app (and so the heartbeat) alive.
- The first connect shows iOS's "Add VPN Configurations" prompt (Allow, then the passcode).
- The provider's own error text is **not** passed back to the app by iOS; only a generic
  reason is (hence the log by message).
- The WireGuard config, private key included, is stored in the VPN configuration
  (`providerConfiguration`) on the phone, not in the Keychain.

**A bug worth remembering:** right after `startVPNTunnel()` the status still reads
"disconnected" for a moment before it becomes "connecting". A loop that took that for a
failure reported "The VPN stopped while connecting" while the tunnel was in fact coming up
(Reset page then worked). The wait now treats "disconnected" as a failure only after the
connection has been seen to start, or after 5 s of nothing.

**Identity trap:** the app first installed on the phone was signed under the old wildcard
profile (App ID prefix `7A5LQN42Z7`); the explicit App ID the extension needs has the team
prefix `EDG4R37566`. iOS refuses to upgrade across that, so the old app had to be deleted
(its logins and folder choice with it). That is a one-time cost, now paid.

The in-process tunnel (`swift/vpn/tunnel`, `TVVPNStart`, the SOCKS5 proxy) is still built, for
the simulator and for `go run ./swift/vpn/cmd/tvvpncheck file.conf [url]`, which brings a
config up and fetches a URL (UK exits in London, IT in Milan). Its known limit: BBC's CDN
(`static.files.bbci.co.uk`, `ichef.bbci.co.uk`) never answers a userspace stack.

### Next, in order

1. **The real workflow on the phone:** log in to BBC iPlayer and RaiPlay and play something
   through the system VPN (BBC also asks about a TV licence). Only the page load and a Rai
   preview have been seen so far. Look for the tunnel's behaviour on Wi-Fi/cellular changes
   and when the app goes to the background while audio plays.
2. **An in-app VPN indicator and a "Disconnect VPN" button** (the VPN no longer outlives the app,
   but nothing in the app says it is up).
3. The Mac, `-config`/`-debug` flags, notarization and the other parity gaps under *macOS
   parity* and *Status*.

### One-time Apple Developer setup (for the iOS system VPN)

At developer.apple.com > Certificates, Identifiers & Profiles > Identifiers, signed in to the
team (`EDG4R37566`):
1. Open the App ID `io.github.raff.tvview.swift` and tick **Network Extensions** under
   Capabilities, then Save.
2. Register a second explicit App ID, `io.github.raff.tvview.swift.tunnel` ("TV View Tunnel"),
   with **Network Extensions** ticked. The extension's bundle ID must be the app's plus a suffix.
3. Profiles need no manual work: building with `-allowProvisioningUpdates` makes Xcode create
   one per App ID (it showed `iOS Team Provisioning Profile: io.github.raff.tvview.swift` and
   `...swift.tunnel`). The old wildcard profile cannot carry the entitlement, which is why
   both IDs have to be explicit.
4. The Apple Developer Program License Agreement must be accepted (Account > Agreements), or
   profile generation fails unhelpfully. The Mac needs none of this (it uses `vpnhelper`).

A packet tunnel is available to a paid team through that checkbox; no request to Apple was
needed. Apple's App Store rules say VPN apps must come from an organization account, which
does not matter for installing from Xcode on your own devices but could for TestFlight or the
App Store from an individual account (check the current guidelines before relying on either).

### Logging in to sites on the phone

Typing passwords on a phone is the annoying part. What works, as tried:
- **iOS Password AutoFill works inside the web view.** Tapping a password field shows the
  key icon / Passwords suggestion above the keyboard and fills from iCloud Passwords (and from
  a third-party manager enabled under Settings > General > AutoFill & Passwords).
- Logins kept only in Chrome are not in iCloud Passwords. On the Mac, **Safari > File > Import
  From > Google Chrome… > Passwords** moves them there, and they sync to the phone.
- A Bitwarden that asks to log in again on every request needs a longer *Vault timeout* and the
  action set to *Lock* (not *Log out*); that is its setting, not the app's.
- **iPhone Mirroring** lets you type with the Mac keyboard, but a password copied from a manager
  usually does not cross the clipboard (password managers mark it local-only).
- Sessions (cookies) are not shared between devices; see *Site logins* in `../PORTING.md` for why
  copying them is the weakest option.

### A frozen page (done in the Swift app; not yet in the Go app)

A page whose web process wedges (a RaiPlay movie whose player never starts; the same
title fails identically in the pre-Swift Go app, so it is the site, not the app)
used to trap the whole window: menus, Cmd-R, resizing and the sidebar all go to the
frozen process and nothing happens; only quitting works. Now, in `WebHost`:

- a watchdog pings the page every 3 s (`evaluateJavaScript("1")`) while the app is
  frontmost; 12 s without an answer marks it `unresponsive`;
- a native bar then offers **Reset page** and a channel menu, outside the page;
- `reset()` builds a new `WKWebView` (own configuration, so its own web process; same
  user scripts and data store, so logins and the VPN proxy carry over) and, on macOS,
  ends the old process: dropping the view does not stop a process stuck in a loop (it
  kept a core at 100% for minutes). The pid comes from WebKit's undocumented
  `_webProcessIdentifier`, macOS only, guarded, and absent on iOS;
- picking a channel, Cmd-R, or **View > Reset Web View** (Cmd-Opt-R) while it is
  unresponsive replaces the view first, so the Channels menu works again.

The ping closure must hold the web view **weakly** (a frozen page never calls back).
Tested with a channel whose page loops forever (`data:text/html;base64,...` with
`setTimeout(function(){for(;;){}},2000)`): flagged at ~15 s, channel switch recovers,
no process left spinning. The Go app has the same trap and no equivalent yet; the port
would be the same ideas through purego (`_webProcessIdentifier` is on the same object
`webView()` already finds).

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

## macOS parity with the Go app

Checked by running both. **Same:** the page scripts (sidebar, hide, media session, settings
panel), config format and search order (iCloud `tvview/`, `~/.config/tvview/`), user agent,
the kernel tunnel via `vpnhelper` (BBC iPlayer loads), the channel and View menus with
the same shortcuts, frozen-page recovery, closing the window quits, and Cmd-Q asks for a
second press (the Quit menu item quits at once, as in the Go app; the two are told apart by
the triggering event).

**Found and fixed while comparing** (both were real gaps in the first Swift builds):
- The page's Fullscreen API was off, so a player's own fullscreen button could not work
  (`document.fullscreenEnabled` was `undefined`; the Go app's embedded library turns it
  on). Now `isElementFullscreenEnabled`. What fullscreen then *looks like* in the SwiftUI
  window was not tried.
- Closing the window left the app running with no window (page still playing, tunnels
  up). Now the app quits with its last window.

**Still different or missing in the Swift app:**
- **Notarization:** `make swift-release` / `swift-install` give a universal, ad-hoc signed
  Release app (the Go app's `make app`/`universal`/`install`); nothing is notarized or
  signed with the Developer ID certificate yet.
- **Flags:** no `-config` or `-debug`; environment variables instead
  (`TVVIEW_CONFIG_FOLDER`, `TVVIEW_HOME`, `TVVPN_USERSPACE`), and the web inspector only
  in Debug builds.
- **First run** does not write a default `channels.yaml`; the built-in one is used until
  the first save from the settings panel.
- **Last channel** is kept in `UserDefaults`, not in the Go app's `last_channel` file, so
  the two apps do not share it.
- **Channels menu** has no checkmark on the current channel.
- Not checked on the Mac Swift app at all: media keys and the headphone seek, Picture in
  Picture, downloads and HTTP auth prompts (the scripts are shared, so the first two are
  likely fine).

## Installing on a Mac, with no password prompts

```sh
make swift-install            # Release build, universal, into /Applications/TV View.app
make install-vpn-helper       # asks for sudo once; covers TV View.app and the Go TVView.app
```

`scripts/install-vpn-helper.sh` writes one NOPASSWD sudoers rule per installed app, each
pinned to that app's `Contents/MacOS/vpnhelper` (paths with spaces are escaped;
`--check` prints and validates what it would write, without root). The shared tunnel code
tries `sudo -n` first and only falls back to the administrator dialog, so after this a
region starts with no prompt. Read the script's header for the trade: the rule trusts
whatever file is at that path, and an app in `/Applications` is normally yours, so
anything running as you could swap the helper and run it as root. Undo with
`scripts/uninstall-vpn-helper.sh`. Installed with `make install-vpn-helper` and confirmed
working on the author's Mac.

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
