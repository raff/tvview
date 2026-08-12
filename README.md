# tvview

A minimal desktop TV/channel viewer. It's a single webview window that loads whatever
site you point it at, plus a sidebar for switching between a list of channels you
define in a YAML file.

No Electron, no CGO — one static binary and a config file.

```
┌──────────────┬──────────────────────────────┐
│ ☰            │                              │
│ ── CHANNELS  │                              │
│  │ PBS       │   the real page, loaded as   │
│    NASA+     │   a normal top-level page    │
│    Al Jazeera│                              │
└──────────────┴──────────────────────────────┘
```

## Build & run

```bash
go build .
./tvview
```

On Windows, build with `-ldflags="-H windowsgui"` to suppress the console window.

Prebuilt native webview libraries for macOS, Linux and Windows (amd64/arm64) are
embedded in the binary, so there is nothing else to install or ship.

### The macOS bundle

```bash
make app        # TVView.app for this machine
make universal  # one bundle for both Intel and Apple Silicon
make install    # copy it to /Applications
```

The bundle carries no resources — the webview library and the default
`channels.yaml` are both compiled in. It exists for what a bare binary cannot
have: a real name in the menubar (`CFBundleName`, so the application menu reads
*TV View* rather than `tvview`), a Dock icon, and no terminal window behind it.

`icon.icns` in the project root is a **placeholder** — a generated squircle with
a play mark. Replace that one file with a real icon and rebuild; nothing else
needs touching, and the `Info.plist` already points at it.

`make universal` compiles each architecture separately before `lipo` joins them:
go-webview selects its embedded native library by `GOARCH` at compile time, so
each slice has to be a finished binary carrying its own.

Both targets ad-hoc sign the result (`codesign --sign -`), which is enough to run
it here. Distributing to other Macs still needs a Developer ID and notarisation.

### Flags

| Flag      | Description                                                    |
| --------- | -------------------------------------------------------------- |
| `-config` | Path to a config file. Overrides the search order below.        |
| `-debug`  | Enable developer tools in the webview.                          |

## Configuration

Channels are read from `channels.yaml`:

```yaml
window:
  title: TV View
  width: 1200
  height: 900

channels:
  - title: PBS
    url: https://www.pbs.org

  - title: NASA+
    url: https://plus.nasa.gov/scheduled-video/nasa-tv/
```

Sidebar order follows file order. On startup the app reopens whichever channel
was last viewed — see *Remembering the last channel* below — falling back to
the first entry when there is no saved channel, or it no longer matches one in
the file. Entries without a `url` are skipped; an entry without a `title`
falls back to showing its URL.

The config is looked up in this order, first hit wins:

1. `-config <path>`
2. `./channels.yaml` (or `.yml`)
3. `$XDG_CONFIG_HOME/tvview/channels.yaml` — defaults to `~/.config/tvview/channels.yaml`
4. Built-in defaults, embedded in the binary

Because of step 4 the binary runs standalone with no config file present — the
defaults are compiled in with `go:embed`, so **a macOS bundle needs no resource
file**; a lone binary is already self-contained.

Embedded defaults are invisible, though, so when the search falls all the way
through to step 4 the app writes them to `~/.config/tvview/channels.yaml` and
says so on stderr. That leaves a real file to open in an editor. It is only a
seed, and deliberately narrow:

- It never overwrites. An existing file is yours, whatever is in it.
- It is skipped entirely when `-config` was given, or when a config was found in
  the working directory. In both cases you already have a file, and a second one
  appearing elsewhere would only confuse matters.
- Failing to write it — read-only home, no home at all — is a message on stderr,
  not a refusal to start.

Note stderr is invisible under a bundle, where double-clicking gives no terminal.
The file's existence at a predictable path is the real discovery mechanism there;
a *Reveal Config in Finder* menu item would be the natural next step.

Changes take effect on restart.

### User agent

Streaming sites choose which player and which stream to serve you from the
`User-Agent` header, and `WKWebView`'s own string is not Safari's — so a site
can hand us a media path that Safari itself would never take. That is what made
some shows play their ads and then stall at the first frame of the programme.

So the web view claims to be Safari by default:

```
Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15
```

The engine underneath really is Safari's, so this is a truthful enough claim as
these things go. Override it with a top-level `user_agent` key:

```yaml
user_agent: >-
  Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15
  (KHTML, like Gecko) Version/26.5 Safari/605.1.15
```

`>-` folds the following lines into one space-joined string, which is only there
to keep the line readable — a single long line works just as well.

The default lives in `config.go` as `defaultUserAgent`, and the seeded
`channels.yaml` carries the same string as an editable copy. **Absent or empty
means the default**, not the stock web view string, so a `channels.yaml` written
before this existed still gets the fix without being edited.

If a site is still unhappy, give it Safari's exact string from this machine —
Safari ▸ Develop ▸ Show Web Inspector, then `navigator.userAgent`. Only
`Version/` tracks the Safari release; the `AppleWebKit/605.1.15` token has been
frozen for years and sites care far less about it than about the word `Safari`
appearing at all.

The override applies to the top document *and* to every iframe under it, which
is the part that matters — the player is usually somebody else's frame. It is
set once before the first navigation, since a page that has already asked who we
are will not ask again. Run with `-debug` to see the string on stderr.

macOS only: it goes through `WKWebView`'s `-setCustomUserAgent:`, and
`menu_other.go` no-ops it elsewhere. A failure to apply it is a line on stderr,
not a refusal to start.

### Watching from another country

RAI and the BBC serve their good material only to addresses in Italy and the UK.
A channel can name a `region`, and tvview raises a WireGuard tunnel for it
before the page is fetched:

```yaml
vpn:
  tunnels:
    IT: ~/.config/tvview/wireguard/IT.conf
    UK: ~/.config/tvview/wireguard/UK.conf

channels:
  - title: RaiPlay
    url: https://www.raiplay.it/
    region: IT
```

Each entry under `tunnels` maps a region name to a WireGuard `.conf` file — the
same `[Interface]`/`[Peer]` file your VPN provider hands you, unmodified, no
`[Socks5]` section or anything else added by hand. A channel that names a
`region` with no matching `tunnels` entry, or a `region` with no `vpn` block at
all, is refused at startup rather than loaded unrouted — that failure mode
would look exactly like a geo-block from the site, not a config mistake, which
is the harder one to debug.

#### How the tunnel is scoped

Unlike `wg-quick` or your VPN provider's own app, none of this touches the
machine's routing table. Each region gets its own real kernel WireGuard
interface — a genuine `utun` device, the same primitive `wg-quick` itself uses
— but tvview never makes it the system default route. Instead, only tvview's
own connections are pinned to that interface, per socket
(`IP_BOUND_IF`/`IPV6_BOUND_IF`), with a route scoped to that interface alone
(`route -ifscope`, not a normal route). The practical effect: switching a
channel to a region routes *that channel's traffic and nothing else* — a
`curl` in another terminal, your regular browser, and any VPN you're already
connected to for something unrelated are all completely unaffected. This is
also what lets two regions stay resident at once (see *What it does and does
not guarantee* below) without one interfering with the other, even though VPN
providers commonly hand every server the same client-side tunnel address —
the scoping is per interface, not per address.

#### Why a real interface, not a plain userspace proxy

The simpler way to build this — and the one tvview used for a while — is a
fully userspace WireGuard implementation with no kernel interface at all,
exposed as a local SOCKS5 proxy. No root, ever. It works for most sites, and
does not work for BBC iPlayer's own asset CDN: confirmed by direct testing,
the identical WireGuard server and exit IP that loads fine over a kernel
tunnel gets silently dropped by that CDN — connection never completes, no
error — the moment the TCP handshake comes from a userspace network stack
instead of the OS kernel's own. That is consistent with CDN-side bot
mitigation fingerprinting the TCP stack itself, something Akamai (which
fronts iPlayer's asset delivery) is known to do aggressively.

A real kernel interface sidesteps that by construction, since the TCP
handshake tvview's traffic produces is then generated by the same kernel code
a real Safari connection would use — it *is* the same code. The cost is the
one privileged step below.

#### The privileged helper

Creating and configuring a kernel network interface needs root; there is no
way around that on macOS. tvview keeps this to the smallest privileged surface
it can: `vpnhelper`, a separate binary bundled alongside the main one
(`TVView.app/Contents/MacOS/vpnhelper`), whose only job is to create one
interface, assign it the address and MTU from the region's `.conf`, bring it
up, add its interface-scoped route, and hand the open device back to the main
— otherwise entirely unprivileged — tvview process over a Unix socket. Then it
exits.

tvview runs it via `osascript ... with administrator privileges`, macOS's own
admin-password dialog, the same kind any ordinary installer uses. There is no
`sudo`, no `sudoers` file, and nothing to configure ahead of time. You'll see
that prompt once per region, the first time a channel needing it is picked in
a given launch; the interface then stays up for the rest of the session (see
below), so switching back and forth between, say, RaiPlay and BBC iPlayer only
ever asks once each.

If even that occasional prompt is annoying — it recurs on every fresh launch,
once per region touched — `make install-vpn-helper` installs a `sudoers.d`
rule scoped to this exact `vpnhelper` binary path for your account only
(`scripts/install-vpn-helper.sh`; asks for your password once, in the
terminal, to install it). After that, tvview elevates it via passwordless
`sudo -n` instead and you won't see any prompt at all; if the rule isn't
installed (or stops matching, e.g. after moving the app), it silently falls
back to the `osascript` dialog above, so this is purely optional. `make
uninstall-vpn-helper` removes the rule.

#### Why WireGuard and not IKEv2

The obvious macOS answer is a native IKEv2 profile per country plus
`["/usr/sbin/scutil", "--nc", "start", "Proton-{region}"]` — no third-party
tools at all. It works today and it is a dead end: Proton began [removing
IKEv2 from their servers in April 2026](https://protonvpn.com/blog/ikev2-ending),
with final shutdown in February 2027. That is server-side, so it takes native
profiles down with it, not just their app. Connections fail intermittently in
the meantime, which is the worst way for this to break.

WireGuard is the replacement, and it isn't a Proton-only choice: it's a plain,
published protocol, so any provider that can hand you a standard
`[Interface]`/`[Peer]` config file works here unchanged. NordVPN, for
instance, is built on it too — NordLynx, their default protocol, *is*
WireGuard with a connection-reuse layer on top — and separately publishes
plain configs for exactly this kind of manual setup.

#### Getting the config files

Regardless of provider, the file you want is a `.conf` with `[Interface]`
(your private key, address) and `[Peer]` (the server's public key, endpoint)
sections. Where it comes from differs:

##### Proton VPN

1. Sign in at **account.protonvpn.com**.
2. **Downloads → WireGuard configuration**.
3. Name it something you'll recognise later — the name is only a label.
4. **Platform** doesn't matter here — every choice emits the same
   `[Interface]`/`[Peer]` file.
5. **Server:** pick a specific country server yourself. Don't take
   "Recommended" — that's chosen by load and proximity to *you*, which from
   the US is never going to be Italy or the UK.
6. **Create**, wait a few seconds, **Download**.

Country selection needs a paid Proton plan; Free gives you a handful of
countries that won't include Italy for RAI.

##### NordVPN

1. Sign in at **my.nordaccount.com** and open the NordVPN service.
2. Find the manual/advanced setup area — NordVPN calls it something like
   "Set up NordVPN manually", separate from the main app download. It's
   there specifically for third-party clients.
3. Pick **WireGuard** and a specific server (by country or hostname, not
   "auto" or "recommended" — same reasoning as Proton above).
4. Generate and download the `.conf`.

NordVPN's manual-setup UI moves around more than Proton's, so treat the exact
labels as approximate — the thing you're looking for is a WireGuard config
generator that lets you pin a specific server, not the regular app's one-click
connect. There's no free tier to worry about; any paid plan can do this.

##### Either way

Put the file where `vpn.tunnels` in `channels.yaml` points. `~/.config/tvview/wireguard/`
is the natural place — created automatically alongside `~/.config/tvview` on
first run, or by `make config` — named to match the region:

```sh
mv ~/Downloads/tvview-italy.conf ~/.config/tvview/wireguard/IT.conf
mv ~/Downloads/tvview-uk.conf    ~/.config/tvview/wireguard/UK.conf
```

Two things worth knowing before they bite:

- **Each file is pinned to one specific server, not to a country.** RAI and
  the BBC block VPN traffic at the CDN edge server by server, not by a single
  country-wide list, so when a channel that used to work starts geo-blocking
  again, regenerating the config against a different server in the same
  country is the usual fix — not a plumbing problem.
- **The `.conf` holds a WireGuard private key in plain text.** `~/.config` is
  your own home directory, not shared, but treat the file the way you would
  any other credential — don't copy it somewhere world-readable.

#### What it does and does not guarantee

The region tvview believes is up is tracked in the process, not probed — a
real interface doesn't make "is this actually routed" any cheaper to ask than
remembering what tvview itself did. A tunnel raised by the provider's own app,
or left from a previous run, is invisible to it and reads as "none".

A channel with a region is never fetched before its tunnel is up: startup
lands on `about:blank` first when the last-viewed channel needs one, and a
failed tunnel leaves you there with the error rather than loading the page
unrouted — a geo-block cached on one unrouted load would outlive the tunnel
that was meant to prevent it.

Once raised, a region's tunnel stays resident for the rest of the process's
life: switching to a channel with no region, or to a different region, never
tears one down. That's deliberate — nothing but this app's own traffic is
ever proxied through it (see *How the tunnel is scoped* above), so there's no
risk of quietly routing something unrelated through another country the way a
system-wide tunnel would, and the tradeoff buys faster switching back and
forth. Two regions' tunnels can be resident at once with no interaction
between them.

That also makes quitting simpler than a shelled-out backend would be. Each
interface lives only as long as tvview holds its file descriptor open —
closing it (`a.vpn.Close()`, called once at shutdown, waiting up to 3s via
`quitVPNGrace` in `main.go` as insurance) tears it down immediately, and so
does the process simply dying, for any reason at all: a crash, Force Quit,
`kill -9`, logout. The OS closes every file descriptor a process held the
moment it's gone, and that includes this one — there's no separate long-lived
process to leak, and no way to leave a tunnel running after tvview isn't.

And the plumbing working is not the same as the stream playing. Both
broadcasters actively block VPN traffic at the CDN edge that serves their
actual video assets — confirmed directly against BBC iPlayer's, see *Why a
real interface, not a plain userspace proxy* above — so expect to try more
than one server if a previously-working one starts failing; regenerating the
`.conf` against a different server in the same country is the usual fix.

### Remembering the last channel

The URL of the current channel is written to
`$XDG_CONFIG_HOME/tvview/last_channel` (defaults to
`~/.config/tvview/last_channel`) every time it changes, and read back on the
next launch. It's a bare text file, not part of `channels.yaml`, since it's
runtime state rather than something you'd hand-edit. A write failure — no home
directory, read-only disk — is logged to stderr and otherwise ignored; it just
means the next launch starts from the first channel again.

## Using it

| Action           | How                                                        |
| ---------------- | ---------------------------------------------------------- |
| Open/close       | Click **☰** (top left), **F9**, or **Cmd-`\`**              |
| Close            | **Esc**, or click anywhere in the page                      |
| Switch channel   | Click an entry, or **Cmd-1**…**Cmd-9**                      |
| Next/previous channel | **Cmd-]** / **Cmd-[**                                  |
| Reload page      | **Cmd-R** (reloads in place — you keep what you're watching) |
| Quit             | **Cmd-Q** twice, or **Quit** in the menu (immediate)        |

The toggle button sits at 22% opacity when idle so it doesn't cover video, and
brightens when you hover it or move the pointer into that corner. It stays **☰**
whether open or closed — clicking the page is the primary way out, so a ✕ would
advertise the lesser of the two.

### Why the panel stays open after a channel switch

Because closing it is one click away, and that click is one you were going to
make anyway. Picking a channel leaves the panel up, so you can try several in a
row without reaching for the toggle each time; the first click on the show
itself puts it away.

That dismissal needs two separate mechanisms, because a click in the page and a
click in the player are not the same event:

| Where you click        | What we see                                              |
| ---------------------- | -------------------------------------------------------- |
| The page proper        | A `pointerdown` on `window`, captured before the page can swallow it |
| Inside an iframe       | Nothing — events never cross a document boundary, whatever the origin |

The second is the case that matters, since the player is nearly always an
iframe. The only trace such a click leaves in the parent is *focus*: the window
blurs and `document.activeElement` becomes the frame element. So a `blur` whose
`activeElement` is an `IFRAME` counts as a click in the player. Testing
`activeElement` is also what stops Cmd-Tab and the menubar from closing the
panel — those blur the window too, but leave focus in `body`.

Two guards keep this from misfiring:

- **A grace window** (`DISMISS_GRACE`, 1.2s) after each page load. Players and ad
  frames routinely grab focus while a page settles, and without it a
  restored-open panel would shut itself the instant it appeared.
- **Dismissal is off while navigating.** Between picking a channel and the new
  page arriving, this document is being torn down; a stray blur on the way out
  would tell Go the panel was closed, and the *next* page would honour that.

The Cmd shortcuts are macOS menubar items and keep working when focus is inside
a player; **F9** and **Esc** do not. See *Quitting, and the menubar* below.

### Fullscreen

There is no app-level fullscreen. Use the player's own fullscreen button on the
page — PBS and most channel players have one.

The web view does not sit directly in the window. `go-webview` makes the
`WKWebView` the window's `contentView`, and that arrangement does not survive an
element fullscreen: WebKit implements it by pulling the web view out of its
superview, parking it in a window of its own, and putting it back afterwards.
`removeFromSuperview` on a contentView sets the window's `contentView` to **nil**,
and WebKit restores the view by re-adding it to the superview it remembered,
never by calling `setContentView:` again. The window therefore came back from
fullscreen with no content view at all — the title collapsed onto the traffic
lights, the close button became unclickable, and the page stayed frozen at its
old size in the bottom-left corner while the window resized around it.

`hostWebView` (`fullscreen_darwin.go`) puts a plain `NSView` in between at
startup, so what WebKit removes and restores is an ordinary subview. The
contentView is the container and never moves, and the web view carries
`NSViewWidthSizable|NSViewHeightSizable` — a property of the view, so it
survives the round-trip — which keeps it filling the container.

This works because the embedded `libwebview` (0.12.0) sets `fullScreenEnabled`
on the macOS `WKPreferences` at startup, so the page's `requestFullscreen()`
calls succeed. WebView2 and WebKitGTK support the API natively. Nothing in the
app has to be involved.

Window-level fullscreen is separate, and on macOS the menubar now provides it:
**View → Enter Full Screen** sends `toggleFullScreen:` down the responder chain
to the `NSWindow`, so it needed no code of its own. That fullscreens the window,
not the player. Windows and Linux still have nothing — `go-webview` exposes no
fullscreen API, and doing it there means reaching through `w.Window()` to the
`HWND` or `GtkWindow`. Not worth it while the players carry the case that
matters.

Two consequences of leaning on page fullscreen, both untested:

- The sidebar is a sibling of the player, not a descendant — it hangs off
  `document.documentElement`. A fullscreen element renders in the top layer with
  only its own subtree, so the sidebar should be invisible while a player is
  fullscreen, F9 included. Exit fullscreen to switch channels.
- **Esc** exits fullscreen normally, but if the panel was left open the sidebar
  claims that keypress first (`sidebar.js:210`) and only closes the panel.

### Quitting, and the menubar

**Cmd-Q twice** quits, the way Chrome does it — the first press puts up a
*Press ⌘Q again to Quit* prompt and arms a two-second window. Choosing **Quit**
from the menu quits at once; it is a deliberate act, where Cmd-Q is easily hit
reaching for Cmd-W or Cmd-Tab. Closing the window and **Ctrl-C** in the terminal
still work, both immediate.

The two paths are told apart by `NSApp.currentEvent` inside the action: a key
equivalent leaves a key-down event, a menu click leaves a mouse event. Chrome's
hold-to-quit is not implemented — that needs key-up monitoring; two presses is
the whole of it.

The prompt is a borderless `NSWindow` at screen-saver level with
`FullScreenAuxiliary`, not anything drawn in the page. The page is exactly where
it would work least: during playback, often fullscreen, where web content takes
the top layer and would cover a DOM toast.

The embedded `libwebview` (0.12.0) creates an `NSApplication`, sets an
activation policy and opens a window, but never builds a main menu — the dylib
contains no `NSMenu`, `setMainMenu` or `keyEquivalent` symbols at all. On macOS
the Quit shortcut *is* a menu item's key equivalent, so with no menu there was
nothing to trigger. The same went for **Cmd-C/Cmd-V**, which hang off the Edit
menu's key equivalents.

`menu_darwin.go` builds one programmatically through `purego/objc` and installs
it as `NSApp.mainMenu` between `webview.New` and `Run`. AppKit dispatches key
equivalents from the main menu inside `sendEvent:`, *before* the event reaches
web content, so these shortcuts work no matter where focus sits — including
inside a cross-origin player iframe, where everything in `sidebar.js` gives up.

The menus are App, Edit, View, Channels and Window.

Most items are wired to standard selectors (`copy:`, `paste:`, `performClose:`,
…) with a **nil target**, which sends them down the responder chain to
`WKWebView` and `NSWindow`. That is what restores copy and paste inside pages,
and AppKit's automatic validation greys them out when the page has nothing
selected. AppKit also injects its own extras into menus it recognises by title —
Dictation and Emoji & Symbols into Edit, tab commands into View, the window list
and tiling commands into Window. Its items come *first*, so ours are not at the
index you would expect.

**Reload** (Cmd-R) sends `WKWebView`'s own `-reload` to the web view, found by
walking down from the window's content view. That reloads *the page you are on*,
wherever inside the site you had navigated to — Cmd-R is for unsticking a player
mid-show, so re-navigating to the channel's URL would throw away the very thing
you were watching. Being native, it also does not need the page's JavaScript to
still be running, which when a player has wedged it often is not.

Finding the view takes some care, because WebKit moves it into a window of its
own when the *player* goes fullscreen. A search that stopped at our window came
back empty exactly then, and the fallback re-navigated to the channel's
URL — so Cmd-R while fullscreen dropped you on the channel's home page, which
looked for a while like a per-channel bug in the sites. The lookup now caches
the view (its identity never changes for the life of the process, and the cache
is warmed at startup before any fullscreen exists) and, if ever cold, searches
every window in `[NSApp windows]` rather than only ours. The fallback asks the
page to reload itself instead of navigating anywhere.

It does not use `reload:` down the responder chain, the way the Edit menu works.
That chain starts at the first responder, so until something in the page has
been clicked it runs window → delegate → NSApp and never reaches the web view,
leaving the item greyed out. Messaging the view directly works whatever holds
focus.

**Show/Hide Sidebar** (Cmd-`\`) and the **Channels** list (Cmd-1 … Cmd-9) have
no AppKit equivalent, so they need something real on the ObjC side to be
messaged. `newMenuTarget` registers a class at runtime with
`objc.RegisterClass`, holding two methods: an action, and `menuNeedsUpdate:` so
the same object can serve as menu delegate. One action selector serves every
item — they are told apart by their **tag**, an index into `menuActions` — which
keeps a single registered method covering a channel list of any length.

Both dynamic menus are refreshed from `menuNeedsUpdate:` just before they open,
rather than pushed on every state change: the sidebar item's title flips between
Show and Hide, and the current channel takes a checkmark. Pulling on open means
the menu cannot drift out of step with the page, and costs nothing while closed.

The sidebar item deliberately does not track its own state. It evaluates
`window.wvToggleSidebar()`, the page calls `setOpen`, and `setOpen` reports back
through the existing `wvSetOpen` binding — so `a.open` is updated by exactly the
path F9 already used, with no second copy of the truth.

Two notes on what macOS overrides:

- The **application menu is titled from the bundle, not from what we pass**. Run
  as a bare binary it shows the process name, `tvview`; from `TVView.app` it
  shows `CFBundleName`, *TV View*. Item titles like *Quit TV View* are ours
  either way and do use `window.title` — keep the two strings in step.
- **Enter Full Screen** is declared as Ctrl-Cmd-F but the system rebinds it to
  its own globe/fn-F default.

**Bundling remains orthogonal**, and `make app` now does it: the bundle supplies
the app *name* in the menubar via `CFBundleName`, a Dock icon, no terminal
window, and proper Cmd-Tab behaviour. It has never been what produces the menu
itself.

One caveat: `terminate:` ends the process without unwinding `main`, so the
deferred `w.Destroy()` never runs. That is ordinary macOS app behaviour and
costs nothing here, but it means cleanup added to that path will not fire.

## How it works

The window is a single webview that navigates to the channel URL directly, at the
top level — the page is *not* in an iframe. That matters: most streaming and news
sites send `X-Frame-Options: DENY` or CSP `frame-ancestors 'none'`, so a shell page
with an embedded frame would show nothing for them.

The sidebar is instead injected into every page as a **native user script**
(`WKUserScript` on macOS, `AddScriptToExecuteOnDocumentCreated` on Windows), via
`webview.Init`. Two consequences make this work where a normal injected `<script>`
would not:

- it re-runs automatically on every navigation, and
- user scripts are not subject to the page's Content-Security-Policy.

The UI lives in a **shadow root** attached to `document.documentElement`, so the
host page's CSS and the sidebar's cannot reach each other.

Since each page load re-runs the script from scratch, the JS side owns no durable
state. Go does: `wvState()` is a bound function the sidebar calls on load to
restore which channel is active and whether the panel was open. `a.current`
itself starts from `last_channel` on disk (see *Remembering the last channel*),
so the same mechanism that survives a navigation also survives a restart.

```
click ──▶ window.wvSelect(url) ──▶ Go: store current, Dispatch ──▶ w.Navigate(url)
                                                                        │
   sidebar re-injected on the new page ◀── window.wvState() ◀────────────┘
```

### Files

| File            | Role                                                       |
| --------------- | ---------------------------------------------------------- |
| `main.go`       | Wiring: load config, bind callbacks, inject scripts, run    |
| `config.go`     | Config structs, YAML loading, search order, defaults        |
| `sidebar.js`    | The injected UI. Embedded via `go:embed`                    |
| `channels.yaml` | Default channel list. Embedded *and* the file you edit      |
| `menu_darwin.go`| The macOS menubar, built with `purego/objc`                 |
| `quit_darwin.go`| Two-press Cmd-Q and its prompt window                       |
| `useragent_darwin.go` | `-setCustomUserAgent:` on the `WKWebView`             |
| `fullscreen_darwin.go` | The container that lets the web view survive fullscreen |
| `menu_other.go` | Deliberate no-ops elsewhere                                 |
| `vpn_wireproxy_darwin.go` | `vpnManager`: one WireGuard tunnel per region, lazily raised and kept resident |
| `vpn_kernel_darwin.go` | The kernel-tunnel backend `vpn_wireproxy_darwin.go` calls into: raises the interface via `vpnhelper`, scopes tvview's own sockets to it (`IP_BOUND_IF`), and resolves DNS through it |
| `vpn_proxy_darwin.go` | Points `WKWebsiteDataStore`'s `proxyConfigurations` at a tunnel's local SOCKS5 port |
| `cmd/vpnhelper/main.go` | The one privileged binary: raises and configures a real kernel interface, hands it off, exits |
| `Makefile`      | Builds `TVView.app`, thin or universal, `vpnhelper` included  |
| `scripts/install-vpn-helper.sh` | Optional: sudoers.d rule so `vpnhelper` elevates passwordlessly instead of prompting via `osascript` (see [The privileged helper](#the-privileged-helper)) |

### Bindings exposed to the page

| Function              | Purpose                                              |
| --------------------- | ---------------------------------------------------- |
| `wvState()`           | Returns `{open, current}` so a fresh page can restore |
| `wvSelect(url)`       | Navigate to a channel                                 |
| `wvSetOpen(open)`     | Persist the panel's open/closed state                 |

### Exposed by the page, for Go

| Function              | Purpose                                              |
| --------------------- | ---------------------------------------------------- |
| `wvToggleSidebar()`   | Lets the View menu reach the panel past an iframe     |

## Adding channel properties

Add a field to `Channel` in `config.go` with matching `yaml` and `json` tags:

```go
type Channel struct {
	Title string `yaml:"title" json:"title"`
	URL   string `yaml:"url"   json:"url"`
	Group string `yaml:"group" json:"group"` // new
}
```

The whole channel list is serialised into `window.__WV_BOOT.channels`, so the new
field is immediately readable from `sidebar.js` — no plumbing in between.

## Known limitations

- **Window position.** `go-webview` exposes `SetSize` but no positioning API, so
  the window lands wherever the platform puts it. On multi-display setups that can
  be off-screen. Fixing it means reaching through `w.Window()` to the native
  `NSWindow`/`HWND`.
- **No app-level fullscreen off macOS.** By design — the page's own player button
  does it, and the macOS View menu covers the window. See *Fullscreen* above.
- **Keyboard shortcuts die inside iframes.** The sidebar only installs itself in
  the top document (`sidebar.js:18`), and a keydown in a cross-origin iframe never
  reaches the parent. Once focus is in an embedded player, **F9** and **Esc** stop
  responding. Menubar shortcuts are immune, so Cmd-`\` is the reliable way to
  reach the sidebar and Cmd-1…9 the reliable way to change channel; **F9** and
  **Esc** remain best-effort. Click-to-dismiss is *not* affected — it reads focus
  rather than events, which is the one signal a frame cannot keep to itself.
- **The menubar is macOS-only**, by necessity rather than omission: Windows and
  Linux do not route shortcuts through an application menu. WebView2 and
  WebKitGTK handle the clipboard keys themselves and the window manager handles
  closing, so `menu_other.go` is a deliberate no-op.
- **No hot reload.** Edit `channels.yaml`, restart.
- **One window.** Channels replace each other; there are no tabs.

## Built with

[abemedia/go-webview](https://github.com/abemedia/go-webview) (purego bindings to
[webview/webview](https://github.com/webview/webview), no CGO),
[gopkg.in/yaml.v3](https://gopkg.in/yaml.v3), and, for VPN regions,
[wireguard-go](https://git.zx2c4.com/wireguard-go) (the kernel interface and
device that `vpnhelper` and `vpn_kernel_darwin.go` drive directly),
[windtf/wireproxy](https://github.com/windtf/wireproxy) (WireGuard `.conf`
parsing), and [things-go/go-socks5](https://github.com/things-go/go-socks5)
(the local proxy `WKWebView` is pointed at).
