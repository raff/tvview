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

Status: parked, pending a check in a real browser.

## The symptom

Cmd-R works well on some channels and badly on others. On the bad ones it does
not reload the player you are watching — it lands you back on the channel's home
page or on the episode page.

## Why

`reload` is `WKWebView`'s own `-reload`, sent to the web view directly (see
`(*app).reload` in `menu_darwin.go`). That reloads whatever URL the *top
document* is at. On the channels that misbehave, the player is a state the site
never wrote into the URL — an SPA view, or a player mounted over an episode
page — so re-loading that URL legitimately returns you to the page the URL names.

This is the site's doing, not the reload's. Chrome's Cmd-R should behave the
same way on those channels. **That is the thing to confirm in a browser**, along
with the next section.

## What to check in the browser, per offending channel

1. Get the player stuck (or just start playing), then hit Cmd-R. Does Chrome
   also drop back to the home/episode page? If yes, our reload is behaving
   correctly and the fix has to avoid reloading the top document at all.
2. Does the URL bar change as you go from the channel's home page into a show?
   If the player *does* have its own URL, a plain reload should keep it — and a
   channel that still drops out is doing something else worth looking at.
3. In devtools, is the player an `<iframe>` or a `<video>` in the page itself?
   This decides which repair below is even available:

| Player is           | Possible in-place repair                          |
| ------------------- | ------------------------------------------------- |
| cross-origin iframe | reset the iframe's `src` from the parent — allowed, it is the parent's own DOM element. Player restarts, surrounding page never navigates. |
| in-page `<video>`   | `video.load()` — restarts a stalled stream with no navigation at all. |
| neither             | nothing but the full-page reload we already do.   |

Rough shape of the iframe case, to try by hand in the console first:

```js
document.querySelectorAll('iframe').forEach(f => { f.src = f.src; });
```

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

Not decided. The browser check should say how many channels the iframe path
would actually cover, which is the number that decides it.
