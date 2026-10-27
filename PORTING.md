# Porting to Swift (Mac + iPad)

Status: **idea, nothing built.** Notes from a discussion of what it would take
to run tvview on an iPad, and whether a Swift rewrite could serve Mac too.

## Why the Go binary can't just be recompiled

- `go-webview` embeds prebuilt libraries for macOS, Linux and Windows only.
  Nothing targets iOS/iPadOS, and Go has no UI layer there.
- iPadOS apps are sandboxed and cannot spawn helpers, so `cmd/vpnhelper`,
  `internal/kernelvpn` (utun + routes) and `scripts/` have no equivalent on iOS.
- `menu_darwin.go`, `quit_darwin.go`, `fullscreen_darwin.go` and
  `useragent_darwin.go` drive AppKit through purego. iPadOS is UIKit, and
  purego's objc bridge is not supported there.

## Proposed shape: one SwiftUI multiplatform app

Xcode's Multiplatform template, iOS and macOS targets sharing most code.
Preferred over Mac Catalyst, which gives a Mac app that feels like an iPad app.

Shared (~90%):

- `WKWebView` wrapper (`NSViewRepresentable` / `UIViewRepresentable` behind a
  small `#if os(macOS)`)
- config loading (Yams for the YAML, or keep the same `channels.yaml` format)
- injection of `sidebar.js`, `hide.js`, `mediasession.js` via `WKUserScript`
- the Go-to-JS bridge, replaced by `WKScriptMessageHandler`
- custom user agent (`defaultUserAgent` in `config.go`, same override key)

Per platform (~10%):

- macOS: SwiftUI `.commands` for menus and Cmd shortcuts (replaces ~900 lines
  of purego/objc), fullscreen, quit behaviour
- iPad: `UIKeyCommand`s, touch handling in the sidebar, `audio` background
  mode, Picture-in-Picture, `allowsInlineMediaPlayback`,
  `mediaTypesRequiringUserActionForPlayback = []` if autoplay is wanted

Nice side effects: media keys / Now Playing via `MPRemoteCommandCenter`
(replaces `mediasession.js` + the headphone-seek work), real signing and
notarisation (replaces the Makefile's ad-hoc `codesign`).

Cost: the "one static binary, no CGO" property and the Linux/Windows builds.
Reasonable compromise is to keep the Go app and add the Swift app beside it,
sharing the three JS files and `channels.yaml`.

## Phases

1. Multiplatform project, `WKWebView`, shared JS files.
2. Port `config.go`, and the bridge: first read `sidebar.js` / `main.go` to
   list exactly which Go-to-JS calls need covering.
3. Per-platform bits above.
4. Shared config / logins (below).
5. VPN (below). Last, biggest.

## VPN

**Decided (see `swift/README.md`, "VPN: where we are and what is next"):** the two
platforms get different tunnels, for different reasons.

- **macOS** must behave like the Go app: a real kernel interface raised by
  `vpnhelper`, with only the web view's traffic bound to it. A system-wide
  Network Extension would fight a company VPN that is up at the same time, and a
  userspace tunnel is dropped by BBC iPlayer's CDN.
- **iOS/iPadOS** uses a `NEPacketTunnelProvider` (system VPN, device-wide while
  connected), which is acceptable there and uses the real TCP stack, so BBC works. Built;
  see `swift/README.md`.

An in-process userspace tunnel (built, working) covers sites that do not mind it
and is what runs today on both platforms.

## Sharing config and logins across machines

Goal: moving to a new machine should not mean logging in to every paid site
again. Two separate problems, with different answers.

### Config (`channels.yaml`)

No separate login: iCloud uses the Apple ID already signed in on each device.
Needs the iCloud capability (paid account, fine).

| Option                         | Notes                                                        |
| ------------------------------ | ------------------------------------------------------------ |
| iCloud Drive document container| A real `channels.yaml` visible/editable in Files and Finder. Best fit. |
| `NSUbiquitousKeyValueStore`    | 1 MB limit, trivial API, no file to edit by hand.            |
| CloudKit                       | Overkill for one small file.                                 |

Keep secrets **out** of the YAML.

Cheap win for the existing Go app, no Swift needed: add the iCloud Drive folder
(`~/Library/Mobile Documents/com~apple~CloudDocs/tvview/`) to the config search
order in `config.go`. It is a plain path on a Mac. Linux/Windows can't see it;
there, a URL or git repo would be the alternative.

### Site logins

Sessions live in `WKWebsiteDataStore` (cookies, localStorage, IndexedDB), local
to each app install. There is no built-in sync. Options, most to least robust:

1. **Credentials in the Keychain, auto-filled by injected JS.** Store
   username/password with `kSecAttrSynchronizable = true` (iCloud Keychain,
   end-to-end encrypted, no extra login). Per-channel login selectors in the
   config (the same way `hide.js` already takes per-channel selectors) fill and
   submit the form. Log in once per machine automatically. Fragile per site:
   selectors change, MFA and captchas break it.
2. **Safari/Passwords AutoFill inside the webview.** Unverified, and probably
   not available: in `WKWebView`, AutoFill of saved passwords generally needs
   the site's domain to be associated with the app (Associated Domains +
   the site's `apple-app-site-association`), which we can't get for third-party
   sites. Needs a quick experiment before relying on it. Third-party password
   manager extensions work in Safari / `SFSafariViewController`, not here.
3. **Sync the session itself** (export cookies via `WKHTTPCookieStore`,
   store in Keychain, `setCookie` on the other machine). Appealing because no
   password is handled, but: session-only cookies have no expiry and may not
   persist; many sites keep tokens in localStorage/IndexedDB, which this does
   not cover; sites may bind sessions to device/IP/user agent and invalidate
   them; concurrent-stream limits and ToS on shared sessions are a risk.
   Treat as an experiment, not a plan.
4. **`SFSafariViewController`** gets Safari's AutoFill and shared logins for
   free, but we lose script injection, the sidebar and per-channel hiding,
   which is the app. Not viable as the main view.

Recommendation: do (1), and run the small experiment for (2) first since it
would make (1) unnecessary where it works.

### Other notes

- Mac App Store builds must be sandboxed: config moves to the app container /
  iCloud, not `~/.config/tvview/`. Developer ID builds can stay unsandboxed.
- App Review risk for a public release (third-party streaming sites + script
  injection). TestFlight or direct install for personal use avoids it.
