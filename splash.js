// Startup splash: a vintage CRT warming up, drawn over the first channel while
// it loads underneath.
//
// Injected into every page like sidebar.js, but only plays when the process has
// just started (boot.splash is the start time, set by Go; none when -nosplash).
// It lives in a shadow root so the site's CSS cannot touch it, and fades out
// to reveal the page. Click or any key skips it. Keep DURATION in step with
// splashDuration in main.go.

(function () {
  "use strict";

  if (window.top !== window.self) return;
  if (window.__wvSplashInstalled) return;
  window.__wvSplashInstalled = true;

  var started = (window.__WV_BOOT || {}).splash;
  var DURATION = 3400;
  // Only for a page that starts loading soon after launch: a channel switched
  // to later gets no splash. The allowance is generous because the script runs
  // when the first response arrives, and a slow site (Netflix) can take seconds
  // to send one. A redirect that makes a second document within the allowance
  // must not replay it, hence the marker.
  if (!started || Date.now() - started > 10000) return;
  try {
    if (sessionStorage.getItem("__wvSplashPlayed")) return;
    sessionStorage.setItem("__wvSplashPlayed", "1");
  } catch (e) {}

  var CSS = "\n  :host { all: initial; }\n  #crt { position: fixed; inset: 0; display: grid; place-items: center; background: #000; cursor: none;\n         animation: out .45s 2.95s ease-in forwards; }\n  @keyframes out { to { opacity: 0; } }\n  #crt.hold, #crt.hold * { animation-play-state: paused !important; }\n  #crt.skip { animation: out .2s forwards; }\n\n  /* The picture: starts as a dot, stretches to a line, then opens up. */\n  #screen {\n    position: absolute; inset: 0; overflow: hidden;\n    background: #0a0f12;\n    transform: scale(0, 0.004);\n    filter: brightness(8) blur(1px);\n    animation: on 1.5s cubic-bezier(.7, 0, .2, 1) .35s forwards;\n  }\n  @keyframes on {\n    0%   { transform: scale(0, 0.004);    filter: brightness(8) blur(2px); }\n    35%  { transform: scale(1, 0.004);    filter: brightness(10) blur(1px); }\n    55%  { transform: scale(1, 0.004);    filter: brightness(10) blur(0); }\n    100% { transform: scale(1, 1);        filter: brightness(1) blur(0); }\n  }\n\n  canvas#noise { position: absolute; inset: 0; width: 100%; height: 100%; opacity: .9;\n                 animation: settle 1.2s 1.3s ease-out forwards; }\n  @keyframes settle { to { opacity: 0; } }\n\n  #logo {\n    position: absolute; inset: 0; display: grid; place-items: center; align-content: center; gap: 1.2vmin;\n    font: 700 11vmin/1 \"Helvetica Neue\", Helvetica, Arial, sans-serif; letter-spacing: .06em;\n    color: #e8f7ee; text-shadow: 0 0 1.2vmin #6dffb0, 0 0 4vmin #1fbf6a;\n    opacity: 0; animation: logo 1.2s 1.9s ease-out forwards;\n  }\n   @keyframes logo { 0% { opacity: 0; filter: blur(6px); } 60% { opacity: 1; filter: blur(0); } 100% { opacity: 1; } }\n\n  /* Test-pattern bars along the bottom, as the signal locks. */\n  #bars { position: absolute; left: 0; right: 0; bottom: 0; height: 14%; display: flex; opacity: 0;\n          animation: bars .6s 1.7s ease-out forwards; }\n  #bars i { flex: 1; }\n  @keyframes bars { to { opacity: .85; } }\n\n  /* Tube: scanlines, a bright rolling band, curvature shading. */\n  #scan { position: absolute; inset: 0; pointer-events: none;\n          background: repeating-linear-gradient(to bottom, rgba(0,0,0,.28) 0 1px, transparent 1px 3px); }\n  #roll { position: absolute; left: 0; right: 0; height: 22%; pointer-events: none;\n          background: linear-gradient(to bottom, transparent, rgba(255,255,255,.07), transparent);\n          animation: roll 2.4s linear infinite; }\n  @keyframes roll { from { top: -25%; } to { top: 105%; } }\n  #vignette { position: absolute; inset: 0; pointer-events: none;\n              background: radial-gradient(ellipse at center, transparent 55%, rgba(0,0,0,.75) 100%);\n              box-shadow: inset 0 0 12vmin 3vmin #000; }\n\n  /* The glow left behind when the picture collapses to a dot. */\n  #glow { position: absolute; width: 3vmin; height: 3vmin; border-radius: 50%; background: #fff;\n          box-shadow: 0 0 6vmin 3vmin rgba(180,255,220,.8); opacity: 0;\n          animation: glow .5s .1s ease-out; }\n  @keyframes glow { 0% { opacity: 0; transform: scale(.2); } 40% { opacity: 1; } 100% { opacity: 0; transform: scale(1.5); } }\n\n\n  @media (prefers-reduced-motion: reduce) {\n    #screen { animation-duration: .01s; animation-delay: 0s; }\n    #roll { display: none; }\n  }\n";
  var HTML = "<div id=\"crt\">\n  <div id=\"glow\"></div>\n  <div id=\"screen\">\n    <canvas id=\"noise\"></canvas>\n    <div id=\"bars\"></div>\n    <div id=\"logo\">TV VIEW</div>\n    <div id=\"roll\"></div>\n    <div id=\"scan\"></div>\n    <div id=\"vignette\"></div>\n  </div>\n</div>";

  var host, hider, ac;

  function remove() {
    if (host && host.parentNode) host.parentNode.removeChild(host);
    if (hider && hider.parentNode) hider.parentNode.removeChild(hider);
    host = hider = null;
    try { if (ac) ac.close(); } catch (e) {}
    // The Swift app hosts this script in a web view of its own, and closes it now.
    try { window.webkit.messageHandlers.splashDone.postMessage(1); } catch (e) {}
  }

  function build() {
    var root0 = document.documentElement;
    if (!root0) return false;

    host = document.createElement("div");
    host.setAttribute("style", "all: initial; position: fixed; inset: 0; z-index: 2147483647;");
    var root = host.attachShadow({ mode: "open" });
    var style = document.createElement("style");
    style.textContent = CSS;
    var wrap = document.createElement("div");
    wrap.innerHTML = HTML;
    wrap.firstElementChild.classList.add("hold");
    root.appendChild(style);
    root.appendChild(wrap);

    // The sidebar's toggle would otherwise sit on top of the splash.
    hider = document.createElement("style");
    hider.textContent = "#__wv_sidebar { display: none !important; }";
    root0.appendChild(hider);
    root0.appendChild(host);

    var bars = root.getElementById("bars");
    ["#c0c0c0", "#c0c000", "#00c0c0", "#00c000", "#c000c0", "#c00000", "#0000c0"].forEach(function (c) {
      var i = document.createElement("i");
      i.style.background = c;
      bars.appendChild(i);
    });

    // Static: a small canvas, scaled up, redrawn every frame.
    var cv = root.getElementById("noise"), ctx = cv.getContext("2d");
    cv.width = 160; cv.height = 90;
    var img = ctx.createImageData(cv.width, cv.height), d = img.data;
    (function frame() {
      if (!host) return;
      for (var i = 0; i < d.length; i += 4) {
        d[i] = d[i + 1] = d[i + 2] = (Math.random() * 255) | 0;
        d[i + 3] = 255;
      }
      ctx.putImageData(img, 0, 0);
      requestAnimationFrame(frame);
    })();

    var crt = root.getElementById("crt");
    var ended = false;
    function listen(on) {
      var f = on ? addEventListener : removeEventListener;
      f("keydown", skip, true);
      f("mousedown", skip, true);
      f("touchstart", skip, true);
    }
    function end() {
      if (ended) return;
      ended = true;
      listen(false);
      remove();
    }
    function skip(e) {
      if (e && e.type === "keydown" && e.metaKey) return; // leave Cmd-shortcuts alone
      listen(false);
      crt.classList.remove("hold");
      crt.classList.add("skip");
      setTimeout(end, 220);
    }
    listen(true);

    // The animation, the sound and the end timer all start at the first frame
    // that is actually rendered. A view that is not on screen yet (a web view
    // still being laid out) does not run requestAnimationFrame, so none of it
    // plays out unseen — the dot and the line at the start would be missed.
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        if (ended || crt.classList.contains("skip")) return;
        crt.classList.remove("hold");
        sound();
        setTimeout(end, DURATION + 200);
      });
    });
    // Insurance: if frames never come, do not leave the page covered forever.
    setTimeout(end, 8000);
    return true;
  }

  // A thump as the tube charges, a rising whine, then static that fades. The
  // web view may refuse audio without a gesture; the splash is fine without it.
  function sound() {
    try {
      var AC = window.AudioContext || window.webkitAudioContext;
      ac = new AC();
      var t = ac.currentTime + 0.3, out = ac.createGain();
      out.gain.value = 0.25; out.connect(ac.destination);

      var thump = ac.createOscillator(), tg = ac.createGain();
      thump.frequency.setValueAtTime(90, t); thump.frequency.exponentialRampToValueAtTime(30, t + 0.25);
      tg.gain.setValueAtTime(0.9, t); tg.gain.exponentialRampToValueAtTime(0.001, t + 0.3);
      thump.connect(tg); tg.connect(out); thump.start(t); thump.stop(t + 0.35);

      var whine = ac.createOscillator(), wg = ac.createGain();
      whine.frequency.setValueAtTime(2000, t + 0.1); whine.frequency.exponentialRampToValueAtTime(15700, t + 1.4);
      wg.gain.setValueAtTime(0.0001, t + 0.1); wg.gain.exponentialRampToValueAtTime(0.05, t + 0.9);
      wg.gain.exponentialRampToValueAtTime(0.012, t + 2.6);
      whine.connect(wg); wg.connect(out); whine.start(t + 0.1); whine.stop(t + 2.8);

      var buf = ac.createBuffer(1, ac.sampleRate * 2, ac.sampleRate), ch = buf.getChannelData(0);
      for (var i = 0; i < ch.length; i++) ch[i] = Math.random() * 2 - 1;
      var hiss = ac.createBufferSource(), hg = ac.createGain();
      hiss.buffer = buf;
      hg.gain.setValueAtTime(0.0001, t + 0.4); hg.gain.exponentialRampToValueAtTime(0.35, t + 0.8);
      hg.gain.exponentialRampToValueAtTime(0.0001, t + 1.9);
      hiss.connect(hg); hg.connect(out); hiss.start(t + 0.4);
      if (ac.state === "suspended") ac.resume();
    } catch (e) {}
  }

  // The document element may not exist yet this early in a load.
  if (!build()) {
    var mo = new MutationObserver(function () {
      if (build()) mo.disconnect();
    });
    mo.observe(document, { childList: true });
  }
})();
