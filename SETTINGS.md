# Settings panel

Status: **steps 1-3 done in the Go app** (saving, the bridge, `settings.js`, gear
button, Cmd-,). Not yet tried in the real app window; the panel itself was
exercised in a browser with a mocked bridge. The Swift side is not started. Written so work can resume from here; see
also `PORTING.md` for the Swift/iPad plan this has to fit.

Goal: add, remove, edit and reorder channels, and edit the global settings, from
a panel reached through the sidebar — written once, in JS, so the Go app and a
future Swift app share it with minimal native changes.

## Design

**Shared (identical on both platforms):**

- `settings.js` (new): a full-height overlay in the sidebar's shadow root.
  Pure DOM built with `createElement`, never `innerHTML` (Trusted Types, see
  `fcf61d1`). Must work with touch as well as mouse.
- The JSON shape is the existing `json:` tags on `Config`, plus `user_agent`
  and the VPN region list. Swift mirrors it with a `Codable` struct. Keep a
  golden YAML/JSON fixture that both implementations test against.

**Bridge (three calls):**

| Call | Purpose |
| --- | --- |
| `wvGetConfig()` → `{config, raw, path, readonly, warnings}` | Structured config, raw YAML text, where it will be saved, and the current tunnel warnings. |
| `wvSaveConfig({config})` or `({raw})` → `{ok, error, warnings, restart:[...]}` | Native validates with its own loader, writes only if valid, keeps a `.bak`. |
| `wvConfigChanged()` (native to JS) | The file changed on disk (e.g. edited on another Mac through iCloud). |

Go: two `Bind`s and one `Eval`. Swift: one `WKScriptMessageHandlerWithReply`.
Validation and file I/O are the only native logic.

**Panel contents:**

- Channels: add / delete / edit title, URL, region (dropdown of known regions),
  hide selectors (one per line). Reorder with up/down buttons plus drag (drag
  alone is poor on iPad). Edits are held until Save.
- Global: window title / width / height; media seek seconds and reverse; user
  agent with "reset to default".
- VPN: region **names only**, with a flag on any that are pending or whose file
  is missing. No paths are shown or editable.
- Raw YAML tab: plain textarea, same validation. The only path that preserves
  comments.

**What applies when:** channels, media settings and the user agent (next page
load) apply immediately; window title/size and VPN need a restart, and the panel
says so after saving.

**Entry points:** gear button in the sidebar footer; Cmd-, on the Mac (new menu
item in Go, `.commands` in Swift); a key command on iPad.

## `vpn.tunnels` handling (implemented)

`vpn.tunnels` stays explicit in the file, so the raw file shows which region maps
to which `.conf`. Saving reconciles it; it never removes an entry and never
rewrites a real path:

1. A pending entry whose `wireguard/NAME.conf` now exists gets the real path.
2. A `NAME.conf` in the wireguard folder with no entry gets one.
3. A channel region with no entry gets `NAME: "### add NAME.conf here"`, plus a
   warning. Saving never fails over a missing file, so a config can be prepared
   before the files are in place.
4. An entry with a real path whose file is missing is kept and flagged.

The pending sentinel is any value that starts with `###` (or is empty). It must
be **quoted** in YAML: unquoted, `### …` is a comment and the value is null, which
the loader also treats as pending. At load time a pending entry is resolved in
memory if `wireguard/NAME.conf` exists beside the config, so a dropped-in file
works without a save; selecting a channel whose file is missing reports the
expected path. The loader still rejects a hand-written config whose channel names
a region with no `tunnels` entry (typo protection); only a save fills those in.

Raw-tab saves are written exactly as typed and only validated, not reconciled.

The panel never sends paths; native code writes the `tunnels` block. The `###`
prefix is the one convention the Swift side must match (put it in the golden
fixtures).

## Saving (implemented, `config_save.go`)

`saveConfig`: build the YAML from structure, load it back through `parseConfig`,
copy the current file to `channels.yaml.bak`, write a temp file in the same
folder, rename it over the target. The original is never moved, so any failure
leaves it untouched. Location: the file that was loaded; for the built-in
defaults, the iCloud folder if it exists, else `~/.config/tvview/`. A structured
save regenerates the YAML, so comments are lost (the `.bak` keeps them). One
`.bak` generation, no `fsync`; both deliberate.

Tests: `config_save_test.go`.

## Decisions and open risks

- **Comments** are lost on structured saves. Go's `yaml.v3` could patch known
  keys in place via `Node`, but Yams (Swift) cannot, so we kept the portable
  behaviour. Revisit only if it annoys.
- **Security:** bindings are visible to the third-party pages the webview loads.
  A save binding would let a malicious page rewrite the config.
  - Swift: run the scripts in an isolated `WKContentWorld` (the real fix).
  - Go: the webview library has no content worlds. Mitigations are no editable
    paths, accepting only the schema above, and the `.bak`. An optional native
    confirm dialog on save was deferred.
- **Concurrent edits** on two Macs are last-write-wins; iCloud will surface a
  conflict file. Accepted.

## What was built (steps 2-3)

- `settings.go`: `configView()` (`wvGetConfig`), `saveFromPanel()` (`wvSaveConfig`,
  takes a JSON string), `applySaved`, `restartReasons`, `openSettings`.
- `settings.js`: tabs Channels / General / Raw YAML. Channels: add, delete,
  drag-to-reorder by the grip (pointer events, so touch works; auto-scrolls
  at the edges) plus up/down buttons that keep the moved card under the pointer, region input with a datalist, hide
  selectors. Dirty tracking, a two-press discard, validation before the round trip. **Save**
  writes and closes (notes such as "restart to apply" and the pending-file
  warnings move to a toast); **Apply** writes and stays open. A failed save
  always keeps the panel open with the reason.
- `sidebar.js`: footer "Settings" button; channels now come from live
  `wvState` (it returns `channels`), `wvConfigChanged()` refreshes the list.
- Menu: Settings… (Cmd-,) in the app menu; the Channels menu is rebuilt on save.
- `a.cfg` is swapped under `a.mu` on save; `channelList()` is the safe reader.
- Tests: `settings_test.go`. The JS was checked by hand in a browser against a
  mocked `wvGetConfig`/`wvSaveConfig`; there is no JS test suite.

**Applies immediately (Go app):** the sidebar list, the Channels menu, the window
title, the user agent (next page load). **Needs a restart:** window size, media
settings, hide selectors (all three are baked into the user scripts injected at
startup, and go-webview cannot remove or replace an injected script) and VPN
region changes (the tunnel manager is built once). The save result lists which
of these changed. In Swift, `removeAllUserScripts()` plus re-adding would make
hide and media live too.

**Known gaps:** keystrokes typed in the panel are stopped at the panel's host
but a page listening in the capture phase on `window` can still see them; no
file watcher yet, so `wvConfigChanged` fires only after the panel's own saves.

## Remaining steps

2. (done) Bridge.
3. (done) `settings.js`, gear button, Cmd-,.
4. Try it in the real app (`make run`), then optional: a file watcher.
5. Swift port: the bridge and the menu only; `settings.js` is reused as is.

## Related, already shipped

- Config is read from iCloud Drive `tvview/` (macOS) before `~/.config/tvview/`;
  `make config`, `make diff-config`, `make edit-config` use it. See the README.
- Logins are per machine and do not sync; options for that are in `PORTING.md`.
