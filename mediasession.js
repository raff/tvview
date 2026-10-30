// Headphone previous/next track -> seek.
//
// WebKit owns the system's "now playing" registration for whatever is playing
// in the web view, and only forwards previous/next to a page that has set
// MediaSession handlers. Most players never do, so the buttons go nowhere.
// Setting them here makes WebKit enable the commands and deliver them, and the
// handler seeks the video directly.
//
// Runs in every frame (players are in iframes). A frame only registers once a
// video in it actually plays, so a frame with no video never claims the
// buttons from the one that has it.

(function () {
  "use strict";

  if (window.__wvMediaSessionInstalled) return;
  window.__wvMediaSessionInstalled = true;
  if (!("mediaSession" in navigator)) return;

  var media = (window.__WV_BOOT || {}).media || {};
  var STEP = media.seekSeconds > 0 ? media.seekSeconds : 10;
  var DIR = media.reverse ? -1 : 1;

  // The rewind_button / forward_button / play_button selectors of this site's
  // channel, matched by host like hide.js. Some players (Disney+) keep a small
  // back-buffer and snap a direct backward currentTime write back into it, so a
  // rewind goes back once and then fights the player. Clicking the player's own
  // control avoids that.
  function host(u) {
    try {
      return new URL(u).hostname.replace(/^www\./, "");
    } catch (e) {
      return "";
    }
  }

  var buttons = { rewind: "", forward: "", play: "" };
  (function () {
    var here = host(location.href);
    var channels = (window.__WV_BOOT || {}).channels || [];
    for (var i = 0; i < channels.length; i++) {
      var c = channels[i];
      if (host(c.url) !== here) continue;
      buttons.rewind = c.rewind_button || buttons.rewind;
      buttons.forward = c.forward_button || buttons.forward;
      buttons.play = c.play_button || buttons.play;
    }
  })();

  var last = null; // the video most recently seen playing

  function pick() {
    if (last && last.isConnected) return last;
    var vids = document.querySelectorAll("video");
    var best = null;
    for (var i = 0; i < vids.length; i++) {
      if (!vids[i].paused) return vids[i];
      if (!best || vids[i].videoWidth > best.videoWidth) best = vids[i];
    }
    return best;
  }

  // querySelector that also looks inside open shadow roots, which is where
  // some players (Disney+) keep their controls.
  function deepQuery(root, selector) {
    var hit = root.querySelector(selector);
    if (hit) return hit;
    var all = root.querySelectorAll("*");
    for (var i = 0; i < all.length; i++) {
      if (all[i].shadowRoot) {
        hit = deepQuery(all[i].shadowRoot, selector);
        if (hit) return hit;
      }
    }
    return null;
  }

  function clickButton(selector) {
    try {
      var b = deepQuery(document, selector);
      if (b) { b.click(); return true; }
    } catch (e) {}
    return false;
  }

  // The controls are often only in the DOM while they are showing, so when the
  // button is missing, nudge the player with a mouse move and retry briefly.
  // fallback runs if the button never appeared.
  function clickWhenReady(selector, v, fallback) {
    if (clickButton(selector)) return;
    var target = v || document.body;
    var r = target.getBoundingClientRect();
    var opts = { bubbles: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
    var n = 0;
    (function retry() {
      ["mousemove", "pointermove"].forEach(function (t) {
        var Ev = t === "pointermove" && window.PointerEvent ? PointerEvent : MouseEvent;
        target.dispatchEvent(new Ev(t, opts));
      });
      setTimeout(function () {
        if (clickButton(selector)) return;
        if (++n < 5) retry();
        else fallback();
      }, 100);
    })();
  }

  function seekVideo(v, delta) {
    var t = v.currentTime + delta;
    var lo = 0, hi = v.duration;
    if (v.seekable && v.seekable.length) {
      lo = v.seekable.start(0);
      hi = v.seekable.end(v.seekable.length - 1);
    }
    if (!isFinite(hi)) hi = t;
    try { v.currentTime = Math.max(lo, Math.min(hi, t)); } catch (e) {}
  }

  function seek(delta) {
    var v = pick();
    if (!v) return;
    var selector = delta < 0 ? buttons.rewind : buttons.forward;
    if (selector) {
      clickWhenReady(selector, v, function () { seekVideo(v, delta); });
      return;
    }
    seekVideo(v, delta);
  }

  // Only takes over play/pause when the channel names a button; otherwise the
  // system's play/pause reaches the video on its own.
  function playPause(play) {
    var v = pick();
    if (!v || v.paused !== play) return; // already in the wanted state
    clickWhenReady(buttons.play, v, function () {
      try { if (play) v.play(); else v.pause(); } catch (e) {}
    });
  }

  function register() {
    try {
      navigator.mediaSession.setActionHandler("previoustrack", function () { seek(-STEP * DIR); });
      navigator.mediaSession.setActionHandler("nexttrack", function () { seek(STEP * DIR); });
      if (buttons.play) {
        navigator.mediaSession.setActionHandler("play", function () { playPause(true); });
        navigator.mediaSession.setActionHandler("pause", function () { playPause(false); });
      }
    } catch (e) {}
  }

  // Capture: media events do not bubble, but they do capture.
  document.addEventListener(
    "playing",
    function (e) {
      if (e.target && e.target.tagName === "VIDEO") {
        last = e.target;
        register();
      }
    },
    true
  );
})();
