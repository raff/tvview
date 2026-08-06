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

Sidebar order follows file order, and the first channel is what loads on startup.
Entries without a `url` are skipped; an entry without a `title` falls back to
showing its URL.

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

## Using it

| Action           | How                                                        |
| ---------------- | ---------------------------------------------------------- |
| Open/close       | Click **☰** (top left), **F9**, or **Cmd-`\`**              |
| Close            | **Esc**                                                     |
| Switch channel   | Click an entry, or **Cmd-1**…**Cmd-9**                      |
| Quit             | **Cmd-Q** twice, or **Quit** in the menu (immediate)        |

The toggle button sits at 22% opacity when idle so it doesn't cover video, and
brightens when you hover it or move the pointer into that corner.

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

- The **application menu is titled from the process name** (`tvview`), not from
  what we pass. That is a bundling matter, not a menu one — see below. Item
  titles like *Quit TV View* are ours and do use `window.title`.
- **Enter Full Screen** is declared as Ctrl-Cmd-F but the system rebinds it to
  its own globe/fn-F default.

**Bundling as `tvview.app` is still worth doing, and remains orthogonal.** A
bundle gives a real app name in the menubar instead of `argv[0]`, a Dock icon,
no terminal window, and proper Cmd-Tab behaviour. It has never been what
produces the menu.

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
restore which channel is active and whether the panel was open.

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
| `menu_other.go` | Deliberate no-op elsewhere                                  |

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
  **Esc** remain best-effort.
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
