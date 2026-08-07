# Open issues

1. [What Cmd-R should reload](#2-what-cmd-r-should-reload)

Fixed, kept for the reasoning:

1. [Playback stalls at the start of the show](#1-playback-stalls-at-the-start-of-the-show)

---

# 1. Playback stalls at the start of the show

Status: **fixed.** It was the user agent — hypothesis 1, the first and cheapest
guess. We were sending `WKWebView`'s own string, which is not Safari's, and the
sites were serving us the media path they serve everything non-Safari. Claiming
to be Safari makes shows play straight through the ad boundary.

The string is now `defaultUserAgent` in `config.go`, overridable per-machine
with `user_agent` in `channels.yaml`; see the README. Everything below is the
reasoning that got there, kept because the shape of the bug is worth
recognising again.

**If it comes back** — a site tightens its sniffing, or macOS moves far enough
that `Version/26.5` reads as implausible — the first move is to put Safari's
current exact string in the config, which needs no rebuild. If that does not do
it, the hypotheses below resume at number 2.

## The symptom

Pick a show on PBS, press play. The pre-roll ads play through fine, and then it
stops at the very beginning of the show proper and stays stuck.

| Where          | Result                                          |
| -------------- | ----------------------------------------------- |
| Chrome         | stalls — this is part of why TVView exists       |
| Safari         | plays fine, same channel, same episode           |
| TVView         | stalls; **worked once**, which is worth explaining |

Now showing up on other channels too, Pluto TV among them, so it is not one
site's bug.

## What is suspicious about that shape

TVView is a `WKWebView` — the same engine as Safari, near enough. Same engine,
opposite outcome, so **the engine is not the variable**. Something about how the
site is being served or configured differs, and the ads-play-then-content-stalls
boundary is exactly where a player switches to a different stream: different
manifest, often different codec, and usually the point where DRM first matters.
The ads are unencrypted; the show is not.

That the ads always play tells us the media stack basically works, and narrows
it to whatever is special about the content stream.

## Hypotheses, most likely first

1. **User agent — this was it.** Ours was the stock `WKWebView` string, which is
   not Safari's. Sites branch hard on this — serving DASH + Widevine to anything
   Chrome-shaped and HLS + FairPlay to Safari. PBS decided we were not Safari
   and handed us the exact path that fails in Chrome. It explained the
   Chrome/TVView-vs-Safari split in one stroke, which is why it was worth
   testing first even though it was also the cheapest to test.
2. **DRM/EME not available to us.** FairPlay in a `WKWebView` is not simply
   Safari's — it depends on how the app is built and signed, and we are an
   unsigned binary loading a prebuilt `libwebview`. If the key-system request
   fails or is never offered, the ads (clear) would play and the show
   (encrypted) would not — precisely what we see.
3. **Codec or MSE handling on the content stream** — the show's stream needs
   something the ad's did not.
4. **Something per-profile in Chrome** (an extension, a blocked request). Only
   explains the Chrome half; kept because Chrome is where it was first seen.

"It worked once" points at cached state — a session, a stored manifest, a DRM
licence — rather than at anything static, and may be the most informative thread
of all. Note what was different, if it ever works again.

*In hindsight:* the DRM hypothesis was the more interesting one and would have
cost a day. The boring guess won, and the tell was in the table above all along
— Chrome and TVView failing together against Safari is a sniffing story, not a
capability story. Two things that differ from the working case in the same way
usually differ for the same reason.

## How to debug it, if it returns

Run with dev tools and watch the ad→content boundary:

```
go build -o /tmp/tvview . && /tmp/tvview -debug
```

In the console, at the moment it stalls:

- `navigator.userAgent` — what are we claiming to be?
- `document.querySelector('video').error` — a `MediaError`; code 3 is a decode
  failure, code 4 is "source not supported". Check inside iframes too.
- `document.querySelector('video').buffered` / `readyState` — starved of data,
  or holding data it cannot decode? Those are different bugs.
- Whether `navigator.requestMediaKeySystemAccess` is called, with which key
  system, and whether it resolves or rejects. Wrapping it in a logging shim
  before pressing play is the clearest way to see this.
- Network: does the content manifest 403, or does it load and then no segments
  follow?

Then do the same in Safari's Web Inspector on the same episode, and diff the
two. The first difference that appears before the stall is the answer.

## The fix

Overriding the user agent turned out to be the two-line change it looked like:
`(*app).webView` in `menu_darwin.go` already handed back the `WKWebView`, and it
takes `setCustomUserAgent:`. That is now `useragent_darwin.go`, fed by
`Config.UserAgent` and defaulting to `defaultUserAgent` in `config.go`.

The config knob shipped alongside the experiment rather than after it, which is
what makes the "if it comes back" note above a config edit rather than a
rebuild.

To see what is actually being sent without opening dev tools, point a channel at
a local server that echoes the `User-Agent` header back; that is how the
plumbing was checked, top document and iframe both. `-debug` also prints the
string on stderr at startup.

---

# 2. What Cmd-R should reload

Status: **browser check done — and it says the diagnosis below was wrong.** The
symptom is real; the explanation was not. See *What the browser actually said*.

## The symptom

Cmd-R works well on some channels and badly on others. On the bad ones it does
not reload the player you are watching — it lands you back on the channel's home
page or on the episode page.

## Why — the original guess, now disproved

`reload` is `WKWebView`'s own `-reload`, sent to the web view directly (see
`(*app).reload` in `menu_darwin.go`). That reloads whatever URL the *top
document* is at. The guess was that on the misbehaving channels the player is a
state the site never wrote into the URL — an SPA view, or a player mounted over
an episode page — so re-loading that URL legitimately returns you to the page
the URL names, and Chrome would do the same.

**It does not.** Every channel tested writes the player into the URL, and a
reload of that URL stays put.

## What the browser actually said

Chrome 151, driven over CDP with our Safari user agent, on a fresh profile.
Each channel was loaded at its configured URL, clicked through into content the
way a viewer would (so an SPA that only `pushState`s would be caught), then
reloaded:

| Channel | URL tracked the click-through? | After reload |
| ------- | ------------------------------ | ------------ |
| PBS      | yes — `/video/<episode-slug>/`        | stays put |
| Pluto TV | yes — `/us/live-tv/<channel-id>`      | stays put |
| Tubi     | yes — `/movies/<id>/<slug>`           | stays put |

Pluto is worth a note: the configured `https://pluto.tv/` immediately redirects
to `/us/live-tv/<id>`, so even the landing page is addressable, and switching
channels inside the SPA rewrites that id. It is the channel the symptom would
have been most likely to describe, and it behaves.

So `-reload` is doing the right thing, the sites are cooperating, and **the
premise that the player is not in the URL is false for every channel we ship**.

### Which repair each player admits

Same run, checking what the player actually is once content is up (ad and auth
frames — `imasdk`, `doubleclick`, `accounts.google` — filtered out):

| Channel    | Player                                  | Repair available |
| ---------- | --------------------------------------- | ---------------- |
| PBS        | cross-origin iframe (`player.pbs.org`)  | iframe `src` reset |
| Pluto TV   | same-origin iframes (`pluto.tv`)        | either |
| Tubi       | in-page `<video>`                       | `video.load()` |
| Al Jazeera | in-page `<video>`                       | `video.load()` |
| DW News    | in-page `<video>`                       | `video.load()` |
| Peacock, NASA+, France 24 | not reached — login wall or a play click headless would not give | unknown |

Every channel that could be reached has one repair or the other, which is the
number the design fork below was waiting on: the in-place path would cover all
of them, not some.

Rough shape of the iframe case, to try by hand in the console first:

```js
document.querySelectorAll('iframe').forEach(f => { f.src = f.src; });
```

## So what is actually causing it — a new suspect

Untested, but it fits the symptom's exact words, and it is in our code rather
than the sites'. `(*app).reload` falls back when it cannot find the web view:

```go
if view := a.webView(); view != 0 {
    view.Send(selReload)
    return
}
a.w.Navigate(a.current)   // <- a.current is the channel's *configured* URL
```

`a.current` is only ever written by `selectChannel`, so it is the channel's home
page — never wherever you browsed to. **If `webView()` ever returns 0, Cmd-R
lands you on the channel's home page**, which is the complaint verbatim.

When would it return 0? `webView()` walks down from the window's `contentView`,
and WebKit reparents the web view into its own window for *player* fullscreen.
That would also explain "works on some channels and badly on others" without the
channels differing at all — what differs is whether you were watching fullscreen
when you hit Cmd-R.

Two things to do with that:

1. **Check it.** Play something fullscreen, hit Cmd-R, see whether you land on
   the channel home. Instrumenting `reload` to log which branch it took would
   settle it in one run.
2. **Fix the fallback regardless.** Re-navigating to the channel URL is the
   wrong thing to do whatever the cause — it discards where you were. Evaluating
   `location.reload()` in the page keeps the current document, and the native
   path stays first for the wedged-JS case that motivated it.

## The design fork, once we know

Either repair above runs as page JavaScript, so neither survives a page whose JS
has itself wedged — which is exactly when the native whole-page reload is still
wanted. So this ends up as two menu items, and the open question is which one
gets Cmd-R:

- **Player first, page as fallback** — Cmd-R reloads the iframe/video in place
  and falls back to the native reload when the page has neither; Shift-Cmd-R
  always does the full reload. Closest to "just reload the player", at the cost
  of Cmd-R meaning something slightly different per channel.
- **Cmd-R stays the full reload** — browser-standard and predictable, with the
  player-only reload on its own key (Cmd-Alt-R). The stuck-player case then
  needs the second shortcut.

Still not decided, but the number it was waiting on is in: **every reachable
channel admits one repair or the other**, so "player first, page as fallback"
would not be ragged across channels the way the second bullet feared. That
argues for the first option.

What has changed is the urgency. The in-place repair was wanted because a plain
reload was thought to drop you out of the player — and it does not. So this is
now a *nice-to-have* for restarting a stalled stream without losing your place,
not a fix for a broken Cmd-R. The broken Cmd-R, if the fullscreen suspect above
holds, is a four-line fix in `reload`'s fallback and has nothing to do with the
fork.
