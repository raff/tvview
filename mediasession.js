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

  function seek(delta) {
    var v = pick();
    if (!v) return;
    var t = v.currentTime + delta;
    var lo = 0, hi = v.duration;
    if (v.seekable && v.seekable.length) {
      lo = v.seekable.start(0);
      hi = v.seekable.end(v.seekable.length - 1);
    }
    if (!isFinite(hi)) hi = t;
    try { v.currentTime = Math.max(lo, Math.min(hi, t)); } catch (e) {}
  }

  function register() {
    try {
      navigator.mediaSession.setActionHandler("previoustrack", function () { seek(-STEP * DIR); });
      navigator.mediaSession.setActionHandler("nexttrack", function () { seek(STEP * DIR); });
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
