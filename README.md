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
| `menu_other.go` | Deliberate no-ops elsewhere                                 |
| `Makefile`      | Builds `TVView.app`, thin or universal                      |

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
[webview/webview](https://github.com/webview/webview), no CGO) and
[gopkg.in/yaml.v3](https://gopkg.in/yaml.v3).
