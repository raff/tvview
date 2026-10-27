// Channel sidebar, injected into every page the webview loads.
//
// This runs as a native user script (WKUserScript / AddScriptToExecuteOnDocument
// Created), so it re-runs on every navigation and is not subject to the page's
// Content-Security-Policy. The UI lives in a shadow root so the host page's CSS
// and ours cannot reach each other.
//
// Provided by Go:
//   window.__WV_BOOT  {channels: [{title, url}, ...]}  static, injected via Init
//   window.wvState()  -> {open, current}               live, survives navigation
//   window.wvSelect(url)
//   window.wvSetOpen(open)
//   window.wvVPNDisconnect()  optional: when bound, the VPN row gets a Disconnect button
//   (state.vpnRegion in wvState, and window.wvVPNRegion(region) pushed, say which region's
//   VPN is up; "" for none. A host that sends neither shows no indicator.)
//   window.wvOpenSettings()   defined by settings.js; the footer button calls it
//
// Provided to Go:
//   window.wvToggleSidebar()  driven by the macOS View menu, which reaches us
//                             even when focus is inside a player iframe

(function () {
  "use strict";

  // Ad frames and embeds would otherwise each grow their own sidebar.
  if (window.top !== window.self) return;
  if (window.__wvSidebarInstalled) return;
  window.__wvSidebarInstalled = true;

  var boot = window.__WV_BOOT || {};
  var channels = boot.channels || [];

  var PANEL_WIDTH = 268;

  // How long after a page settles to ignore the focus-based dismissal below.
  // Players and ad frames routinely grab focus as a page loads, and without
  // this a restored-open panel would shut itself the moment it appeared.
  var DISMISS_GRACE = 1200;

  var open = false;
  var current = "";
  var settledAt = 0;
  var navigating = false;
  // navigating suppresses click-away dismissal while a channel switch tears this page
  // down. It must not outlive the switch: when the new page never arrives (a tunnel
  // that fails to start, a site that hangs) this page stays, and a flag left set
  // forever made clicking outside stop closing the panel.
  var vpnRegion = ""; // the region whose VPN is up, "" for none
  var vpnRow, vpnText, vpnOff;
  var NAVIGATING_FOR = 6000;
  var navigatingTimer = 0;
  var host, wrap, toggle, list, vpnBox, vpnSpin, vpnMsg;

  // Go may report a tunnel before build() has run — the eval races the user
  // script on a fresh document. Hold the last state and apply it on build.
  var vpnPending = null;

  var CSS = [
    ":host { all: initial; }",
    "* { box-sizing: border-box; margin: 0; padding: 0; }",

    // The panel is PANEL_WIDTH wide, less on a narrow screen so the back/forward
    // pill (top right, about 130px) never lands on the panel's close button.
    ".wrap { --pw: min(" + PANEL_WIDTH + "px, calc(100% - 150px)); }",
    ".toggle {",
    "  position: fixed; top: calc(10px + var(--st, 0px)); left: calc(10px + var(--sl, 0px));",
    "  width: 36px; height: 36px;",
    "  display: flex; align-items: center; justify-content: center;",
    "  font: 15px/1 -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;",
    "  color: #e9e9ee;",
    "  background: rgba(18,18,22,0.72);",
    "  border: 1px solid rgba(255,255,255,0.16);",
    "  border-radius: 9px;",
    "  -webkit-backdrop-filter: blur(10px); backdrop-filter: blur(10px);",
    "  cursor: pointer; opacity: 0.22; z-index: 2;",
    "  transition: opacity .18s ease, left .24s cubic-bezier(.4,0,.2,1);",
    "}",
    // Idle-faded so it does not sit on top of video; wakes on hover or when open.
    ".toggle:hover, .wrap.open .toggle, .wrap.near .toggle { opacity: 1; }",
    // A VPN is up: the button is tinted, brighter than its idle fade, and wears a dot.
    ".wrap.vpnup .toggle { opacity: 0.75; color: #9be3b4; border-color: rgba(76,211,123,0.85); }",
    ".wrap.vpnup .toggle::after {",
    "  content: ''; position: absolute; top: 4px; right: 4px;",
    "  width: 7px; height: 7px; border-radius: 50%; background: #4cd37b;",
    "}",
    ".vpnrow {",
    "  display: none; align-items: center; gap: 8px;",
    "  margin: 0 12px 6px; padding: 6px 10px; border-radius: 8px;",
    "  font-size: 12px; color: #9be3b4;",
    "  background: rgba(76,211,123,0.12); border: 1px solid rgba(76,211,123,0.35);",
    "}",
    ".vpnrow.on { display: flex; }",
    ".vpnrow .vpntext { flex: 1; min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }",
    // At the bottom, away from the channels, so it is not hit by mistake.
    ".vpnoff {",
    "  display: none; margin: 0 12px 8px; padding: 8px 10px; border-radius: 8px;",
    "  font: inherit; font-size: 12px; color: #ffc2bc; cursor: pointer; text-align: center;",
    "  background: rgba(255,120,110,0.08); border: 1px solid rgba(255,120,110,0.35);",
    "}",
    ".vpnoff.on { display: block; }",
    ".vpnoff:hover { background: rgba(255,120,110,0.18); }",
    // Open, it is the panel's close button: inside it, at the top right.
    ".wrap.open .toggle { left: calc(var(--pw) - 46px); }",

    // Back and forward live in the panel header, left of the title: no floating
    // control to sit on a site's own buttons, and nothing to place differently on
    // a phone with a camera cutout. (Cmd-Left/Right and the View menu do the same.)
    ".hnav { display: flex; gap: 4px; margin-right: 10px; flex: none; }",
    ".hnav button {",
    "  width: 30px; height: 30px;",
    "  display: flex; align-items: center; justify-content: center;",
    "  font: 20px/1 -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;",
    "  color: #e9e9ee;",
    "  background: rgba(255,255,255,0.06);",
    "  border: 1px solid rgba(255,255,255,0.12); border-radius: 8px;",
    "  cursor: pointer;",
    "}",
    ".hnav button:hover { background: rgba(255,255,255,0.14); }",
    ".head .title { min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }",

    ".panel {",
    "  position: fixed; top: 0; left: 0;",
    "  width: var(--pw); height: 100%;",
    "  display: flex; flex-direction: column;",
    "  padding: var(--st, 0px) 0 var(--sb, 0px) var(--sl, 0px);",
    "  font: 13px/1.4 -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;",
    "  color: #e9e9ee;",
    "  background: rgba(16,16,20,0.94);",
    "  -webkit-backdrop-filter: blur(18px); backdrop-filter: blur(18px);",
    "  border-right: 1px solid rgba(255,255,255,0.1);",
    "  box-shadow: 0 0 40px rgba(0,0,0,0.45);",
    "  transform: translateX(-100%); z-index: 1;",
    "  transition: transform .24s cubic-bezier(.4,0,.2,1);",
    "}",
    ".wrap.open .panel { transform: none; }",
    ".wrap.no-anim .panel, .wrap.no-anim .toggle { transition: none; }",

    ".head {",
    // Tall enough to centre the title on the close button at its right.
    "  display: flex; align-items: center; min-height: 56px; padding: 0 56px 0 16px;",
    "  font-size: 11px; font-weight: 600;",
    "  letter-spacing: .09em; text-transform: uppercase;",
    "  color: rgba(233,233,238,0.45);",
    "}",

    ".list { flex: 1; overflow-y: auto; padding: 4px 8px 8px; list-style: none; }",
    ".list::-webkit-scrollbar { width: 8px; }",
    ".list::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.14); border-radius: 4px; }",

    ".item {",
    "  display: flex; align-items: center; gap: 8px;",
    "  width: 100%; text-align: left;",
    "  padding: 9px 12px; margin-bottom: 2px;",
    "  font: inherit; color: #e9e9ee;",
    "  background: none; border: 0; border-radius: 7px;",
    "  cursor: pointer; position: relative;",
    "  transition: background .12s ease;",
    "}",
    // The ellipsis lives on the label, not the button: a long title has to
    // give way to the region tag rather than push it out of the panel.
    ".item .name {",
    "  flex: 1; min-width: 0;",
    "  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;",
    "}",
    ".item:hover { background: rgba(255,255,255,0.08); }",
    ".item.active { background: rgba(255,255,255,0.12); font-weight: 600; }",
    ".item.active::before {",
    "  content: ''; position: absolute; left: 3px; top: 50%;",
    "  width: 3px; height: 16px; margin-top: -8px;",
    "  background: #5b9dff; border-radius: 2px;",
    "}",

    ".foot {",
    "  padding: 10px 16px 14px;",
    "  border-top: 1px solid rgba(255,255,255,0.08);",
    "  font-size: 11px; color: rgba(233,233,238,0.35);",
    "}",
    ".foot { display: flex; align-items: center; justify-content: space-between; gap: 8px; }",
    ".foot .gear {",
    "  flex: none; font: inherit; color: rgba(233,233,238,0.6);",
    "  background: none; border: 1px solid rgba(255,255,255,0.14); border-radius: 6px;",
    "  padding: 3px 8px; cursor: pointer;",
    "}",
    ".foot .gear:hover { color: #e9e9ee; background: rgba(255,255,255,0.08); }",
    ".foot kbd {",
    "  font: inherit; padding: 1px 5px;",
    "  background: rgba(255,255,255,0.1); border-radius: 4px;",
    "}",

    // Region tag on channels that route through a tunnel, so it is visible
    // which ones will pause to connect before anything plays.
    ".badge {",
    // The right-alignment is `.item .name { flex: 1 }` pushing this along —
    // `.item` is a flex container, where float computes as none.
    "  margin-left: 8px;",
    "  padding: 1px 5px; border-radius: 4px;",
    "  font-size: 10px; font-weight: 600; letter-spacing: .04em;",
    "  color: #9ecbff; background: rgba(91,157,255,0.16);",
    "}",

    // Status while a tunnel comes up. Centred on the page, in a lighter box:
    // the page behind is usually black, and this is the only sign that the
    // pause is doing something.
    ".vpn {",
    "  position: fixed; top: 50%; left: 50%;",
    "  transform: translate(-50%, -50%); max-width: 70%; min-width: 260px;",
    "  display: none; align-items: center; justify-content: center; gap: 16px;",
    "  padding: 24px 34px;",
    "  font: 500 20px/1.35 -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;",
    "  color: #f4f4f8;",
    "  background: rgba(58,58,68,0.96);",
    "  -webkit-backdrop-filter: blur(18px); backdrop-filter: blur(18px);",
    "  border: 1px solid rgba(255,255,255,0.22); border-radius: 14px;",
    "  box-shadow: 0 10px 40px rgba(0,0,0,0.6);",
    "  z-index: 3;",
    "}",
    ".vpn.on { display: flex; }",
    ".vpn.err { border-color: rgba(255,120,110,0.6); color: #ffc2bc; }",
    // pre-wrap: an error can carry a few lines of a log, and the line breaks matter.
    ".vpn .msg { overflow-wrap: anywhere; white-space: pre-wrap; }",
    ".spin {",
    "  width: 24px; height: 24px; flex: none; border-radius: 50%;",
    "  border: 3px solid rgba(255,255,255,0.28); border-top-color: #6aa8ff;",
    "  animation: sp .7s linear infinite;",
    "}",
    ".vpn.err .spin { display: none; }",
    "@keyframes sp { to { transform: rotate(360deg); } }"
  ].join("\n");

  // A page with no mobile viewport tag is laid out about 980px wide and shrunk to
  // fit a phone, and anything injected into it is shrunk with it. Undo that:
  // size the host to the visible area in screen pixels and scale it by the
  // inverse of the page's zoom, so one unit inside is one pixel on the screen.
  // The panels use percentages (never vw/vh, which stay in the layout
  // viewport's units) so they follow the host. At zoom 1, which is every
  // ordinary page and the desktop, this does nothing. Shared with settings.js.
  //
  // The zoom is the screen's width in points divided by the visible width in
  // CSS pixels, where the app reports the screen (window.__wvSafe.width, set by
  // wvSafeArea), and visualViewport.scale otherwise. vv.scale and vv.width can
  // disagree for a moment while a page is being laid out, and using their
  // product squashed the whole UI into a sliver; this takes one number from the
  // app and one from the page, and corrects itself on the next resize.
  var fits = [];
  window.__wvFitViewport = function (el) {
    var vv = window.visualViewport;
    if (!vv) return;
    var last = "";
    function fit() {
      var safe = window.__wvSafe || {};
      var w = safe.width || vv.width * vv.scale;
      var h = safe.height || vv.height * vv.scale;
      var s = safe.width && vv.width > 0 ? safe.width / vv.width : vv.scale;
      var mode;
      if (!(s > 0) || Math.abs(s - 1) < 0.02) {
        mode = "plain";
        el.style.width = "0";
        el.style.height = "0";
        el.style.transform = "";
      } else {
        mode = "scaled " + s.toFixed(3) + " " + Math.round(w) + "x" + Math.round(h);
        el.style.width = w + "px";
        el.style.height = h + "px";
        el.style.transformOrigin = "0 0";
        el.style.transform = "translate(" + vv.offsetLeft + "px, " + vv.offsetTop + "px) scale(" + 1 / s + ")";
      }
      if (mode !== last) {
        last = mode;
        log("viewport " + mode + " (vv " + vv.width + "x" + vv.height + " @" + vv.scale + ")");
      }
    }
    fits.push(fit);
    vv.addEventListener("resize", fit);
    vv.addEventListener("scroll", fit);
    fit();
  };

  // Diagnostics for the app's log; a no-op where the host does not bind it.
  function log(msg) {
    if (window.wvLog) window.wvLog(msg);
  }

  // Screen areas the page is drawn under but must not put controls in: the
  // camera cutout, rounded corners, the home indicator. The page itself cannot
  // see them (env(safe-area-inset-*) is 0 in a web view that extends under
  // them), so the app reports them: {top, left, bottom, right} in screen
  // points. They become --st/--sl/--sb/--sr on each of our hosts, and the CSS
  // keeps controls inside. Called again when the device turns, and after each
  // page commits; kept in window.__wvSafe for hosts built later.
  function applySafe(h) {
    var i = window.__wvSafe || {};
    [["--st", "top"], ["--sl", "left"], ["--sb", "bottom"], ["--sr", "right"]].forEach(function (p) {
      h.style.setProperty(p[0], (i[p[1]] || 0) + "px");
    });
  }
  window.__wvApplySafe = applySafe;
  window.wvSafeArea = function (insets) {
    window.__wvSafe = insets || {};
    ["__wv_sidebar", "__wv_settings"].forEach(function (id) {
      var h = document.getElementById(id);
      if (h) applySafe(h);
    });
    fits.forEach(function (f) { f(); }); // the screen size may have changed
  };

  function build() {
    host = document.createElement("div");
    host.id = "__wv_sidebar";
    // Inline `all: initial` keeps the host page's own `div {}` rules off us.
    host.setAttribute(
      "style",
      "all: initial; position: fixed; top: 0; left: 0; width: 0; height: 0; z-index: 2147483647;"
    );

    var root = host.attachShadow({ mode: "open" });

    var style = document.createElement("style");
    style.textContent = CSS;

    wrap = document.createElement("div");
    wrap.className = "wrap no-anim";

    // Stays ☰ whether open or closed: clicking the page is what closes the
    // panel now, so a ✕ would advertise the lesser of the two ways out. It
    // still toggles, since a button that does nothing when open is worse.
    toggle = document.createElement("button");
    toggle.className = "toggle";
    toggle.type = "button";
    toggle.title = "Channels (F9)";
    toggle.textContent = "\u2630";
    toggle.addEventListener("click", function () {
      setOpen(!open, true);
    });

    var panel = document.createElement("nav");
    panel.className = "panel";

    var head = document.createElement("div");
    head.className = "head";
    var hnav = document.createElement("div");
    hnav.className = "hnav";
    [["\u2039", "Back (\u2318\u2190)", -1], ["\u203A", "Forward (\u2318\u2192)", 1]].forEach(function (d) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = d[0];
      b.title = d[1];
      b.setAttribute("aria-label", d[1]);
      b.addEventListener("click", function () {
        history.go(d[2]);
      });
      hnav.appendChild(b);
    });
    var title = document.createElement("span");
    title.className = "title";
    title.textContent = "Channels";
    head.appendChild(hnav);
    head.appendChild(title);

    vpnRow = document.createElement("div");
    vpnRow.className = "vpnrow";
    vpnText = document.createElement("span");
    vpnText.className = "vpntext";
    vpnOff = document.createElement("button");
    vpnOff.type = "button";
    vpnOff.className = "vpnoff";
    vpnOff.textContent = "Disconnect VPN and quit";
    vpnOff.title = "Turn the VPN off and close the app";
    vpnOff.addEventListener("click", function () {
      if (window.wvVPNDisconnect) window.wvVPNDisconnect();
    });
    vpnRow.appendChild(vpnText);

    list = document.createElement("ul");
    list.className = "list";

    var foot = document.createElement("div");
    foot.className = "foot";
    // Not innerHTML: sites that enforce Trusted Types (YouTube) throw on it,
    // which would abort build() before the sidebar is ever attached.
    function key(t) {
      var k = document.createElement("kbd");
      k.textContent = t;
      return k;
    }
    var hint = document.createElement("span");
    hint.appendChild(key("F9"));
    hint.appendChild(document.createTextNode(" toggle · "));
    hint.appendChild(key("Esc"));
    hint.appendChild(document.createTextNode(" or click the page to close"));
    foot.appendChild(hint);

    var gear = document.createElement("button");
    gear.className = "gear";
    gear.type = "button";
    gear.title = "Edit channels and settings (\u2318,)";
    gear.textContent = "\u2699 Settings";
    gear.addEventListener("click", function () {
      if (!window.wvOpenSettings) return;
      // Out of the way: the dialog is modal and Esc should close one thing.
      setOpen(false, true);
      window.wvOpenSettings();
    });
    foot.appendChild(gear);

    vpnBox = document.createElement("div");
    vpnBox.className = "vpn";
    vpnSpin = document.createElement("div");
    vpnSpin.className = "spin";
    vpnMsg = document.createElement("span");
    vpnMsg.className = "msg";
    vpnBox.appendChild(vpnSpin);
    vpnBox.appendChild(vpnMsg);

    panel.appendChild(head);
    panel.appendChild(vpnRow);
    panel.appendChild(list);
    panel.appendChild(vpnOff);
    panel.appendChild(foot);
    wrap.appendChild(toggle);
    wrap.appendChild(panel);
    wrap.appendChild(vpnBox);
    root.appendChild(style);
    root.appendChild(wrap);

    renderList();
    document.documentElement.appendChild(host);
    window.__wvFitViewport(host);
    applySafe(host);

    // A status that arrived while the DOM was still being assembled.
    if (vpnPending) {
      var s = vpnPending;
      vpnPending = null;
      window.wvVPN(s);
    }
  }

  function renderList() {
    list.textContent = "";
    channels.forEach(function (ch) {
      var li = document.createElement("li");
      var btn = document.createElement("button");
      btn.className = "item" + (ch.url === current ? " active" : "");
      btn.type = "button";
      btn.title = ch.url;

      var name = document.createElement("span");
      name.className = "name";
      name.textContent = ch.title;
      btn.appendChild(name);

      if (ch.region) {
        var tag = document.createElement("span");
        tag.className = "badge";
        tag.textContent = ch.region;
        btn.appendChild(tag);
      }

      btn.addEventListener("click", function () {
        select(ch.url);
      });
      li.appendChild(btn);
      list.appendChild(li);
    });
  }

  // Shows which region's VPN is up (or none): the button's tint and dot, and the row in the
  // panel with its Disconnect button when the host can disconnect.
  function applyVPN() {
    if (!wrap) return;
    wrap.classList.toggle("vpnup", !!vpnRegion);
    vpnRow.classList.toggle("on", !!vpnRegion);
    vpnOff.classList.toggle("on", !!vpnRegion && !!window.wvVPNDisconnect);
    vpnText.textContent = vpnRegion ? "VPN connected: " + vpnRegion : "";
    toggle.title = (open ? "Close (F9)" : "Channels (F9)") + (vpnRegion ? " \u2014 VPN " + vpnRegion : "");
  }

  // Pushed by the host when the VPN comes up or goes away.
  window.wvVPNRegion = function (region) {
    vpnRegion = region || "";
    applyVPN();
  };

  function setOpen(next, notify) {
    open = !!next;
    wrap.classList.toggle("open", open);
    toggle.setAttribute("aria-expanded", open ? "true" : "false");
    toggle.textContent = open ? "\u2715" : "\u2630";
    toggle.title = (open ? "Close (F9)" : "Channels (F9)") + (vpnRegion ? " \u2014 VPN " + vpnRegion : "");
    if (notify && window.wvSetOpen) window.wvSetOpen(open);
  }

  // The panel deliberately stays open across a channel switch, so several
  // channels can be tried without reaching for the toggle each time.
  //
  // From here until the new page replaces us, dismissal is off: this document
  // is being torn down, and a stray blur on the way out would tell Go the
  // panel was closed — which the *next* page would then honour.
  function select(url) {
    current = url;
    navigating = true;
    clearTimeout(navigatingTimer);
    navigatingTimer = setTimeout(function () {
      navigating = false;
    }, NAVIGATING_FOR);
    renderList();
    if (window.wvSelect) window.wvSelect(url);
  }

  // The menubar's way in. setOpen notifies Go, so a.open stays in step exactly
  // as it does for F9. The guard matters: this is reachable from the menu the
  // moment the script runs, which can be before build() has made `wrap`.
  window.wvToggleSidebar = function () {
    if (wrap) setOpen(!open, true);
  };

  // Go's way in, for the wait while a tunnel comes up.
  //   {state: "working", text}  spinner and message
  //   {state: "error",   text}  message, no spinner, stays until dismissed
  //   {state: "idle"}           hide
  //
  // An error deliberately has no timeout: it is shown because the channel did
  // not load, and the page underneath is the one being left, so there is
  // nothing for it to obscure.
  window.wvVPN = function (s) {
    s = s || {};
    if (!vpnBox) {
      vpnPending = s;
      return;
    }
    // A failed switch leaves this page in place: it is no longer going anywhere.
    if (s.state === "error") {
      navigating = false;
      clearTimeout(navigatingTimer);
    }
    var on = s.state === "working" || s.state === "error";
    vpnBox.classList.toggle("on", on);
    vpnBox.classList.toggle("err", s.state === "error");
    vpnMsg.textContent = s.text || "";
  };

  // Wake the toggle button when the pointer approaches the left edge, so it
  // stays discoverable without permanently covering the page.
  function trackEdge() {
    window.addEventListener(
      "mousemove",
      function (e) {
        // In screen pixels, whatever the page's zoom: clientX/Y are in layout
        // units, which a zoomed-out page makes several times too large.
        var vv = window.visualViewport;
        var s = vv ? vv.scale : 1;
        var x = (e.clientX - (vv ? vv.offsetLeft : 0)) * s;
        var y = (e.clientY - (vv ? vv.offsetTop : 0)) * s;
        var top = (window.__wvSafe && window.__wvSafe.top) || 0;
        wrap.classList.toggle("near", x < 90 && y < 160 + top);
      },
      true
    );
  }

  // isOurs reports whether an event came from the sidebar's own UI. Events
  // crossing a shadow boundary are retargeted to the host by the time they
  // reach window, so composedPath is the honest test; the fallback is for the
  // retargeted case, which is all we would see without it.
  function isOurs(e) {
    if (e.composedPath) return e.composedPath().indexOf(host) !== -1;
    return e.target === host || (host.contains && host.contains(e.target));
  }

  // Closing on a click in the page is what lets the panel stay open after a
  // channel switch: channel-hopping costs no extra clicks, and the first click
  // on the show itself puts the panel away.
  //
  // Two events, because one is not enough. A click in the page proper we see
  // directly. A click inside an iframe we never see at all — events do not
  // cross a document boundary, whatever the origin — and the player is nearly
  // always an iframe, which is the case that matters most here.
  function bindDismiss() {
    // Capture, and pointerdown rather than click: pages stop propagation on
    // their own click handlers freely, and pointerdown lands before the page
    // has had its chance to.
    window.addEventListener(
      "pointerdown",
      function (e) {
        if (!open || navigating) return;
        if (isOurs(e)) return;
        setOpen(false, true);
      },
      true
    );

    // The iframe case. Focus moving into a frame blurs this window and leaves
    // the frame element as activeElement — the only trace of the click we get.
    // Testing activeElement is also what keeps Cmd-Tab and the menubar from
    // closing the panel: those blur the window too, but leave focus in body.
    window.addEventListener("blur", function () {
      if (!open || navigating) return;
      if (Date.now() < settledAt) return;
      var el = document.activeElement;
      if (el && el.tagName === "IFRAME") setOpen(false, true);
    });
  }

  function bindKeys() {
    // Capture phase: pages happily swallow keydown on their own handlers.
    window.addEventListener(
      "keydown",
      function (e) {
        if (e.key === "F9") {
          e.preventDefault();
          e.stopPropagation();
          setOpen(!open, true);
        } else if (e.key === "Escape" && open) {
          e.preventDefault();
          e.stopPropagation();
          setOpen(false, true);
        }
      },
      true
    );
  }

  // Some pages replace documentElement (document.write, framework takeovers),
  // which would take the sidebar with it.
  function keepAttached() {
    new MutationObserver(function () {
      if (!host.isConnected && document.documentElement) {
        document.documentElement.appendChild(host);
      }
    }).observe(document, { childList: true, subtree: true });
  }

  // Go owns open/current so they survive navigation. Ask for them once the
  // binding is available; the UI is already usable before this resolves.
  function applyState(attempt) {
    if (!window.wvState) {
      if (attempt < 50) setTimeout(function () { applyState(attempt + 1); }, 20);
      else releaseAnimations();
      return;
    }
    Promise.resolve(window.wvState()).then(
      function (state) {
        state = state || {};
        // Live, so a list edited since startup (settings panel) wins over
        // the copy baked into the page at injection.
        if (state.channels) channels = state.channels;
        vpnRegion = state.vpnRegion || "";
        applyVPN();
        current = state.current || "";
        renderList();
        setOpen(!!state.open, false);
        if (state.vpn) window.wvVPN(state.vpn);
        releaseAnimations();
      },
      releaseAnimations
    );
  }

  // The settings panel saved: take the new list without a page load.
  window.wvConfigChanged = function () {
    if (!window.wvState) return;
    Promise.resolve(window.wvState()).then(function (state) {
      if (state && state.channels) {
        channels = state.channels;
        renderList();
      }
    });
  };

  function releaseAnimations() {
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        wrap.classList.remove("no-anim");
      });
    });
  }

  // Tells the host this page is still running. A page whose script thread is
  // wedged stops calling, which is how the host knows to end its process
  // (wvPing exists in the Go app only; the Swift app asks the page itself).
  function startPing(attempt) {
    attempt = attempt || 0;
    // Bindings arrive just after user scripts start; wait for it as applyState does.
    if (!window.wvPing) {
      if (attempt < 50) setTimeout(function () { startPing(attempt + 1); }, 20);
      return;
    }
    window.wvPing();
    setInterval(function () {
      window.wvPing();
    }, 3000);
  }

  function start() {
    settledAt = Date.now() + DISMISS_GRACE;
    build();
    trackEdge();
    bindKeys();
    bindDismiss();
    keepAttached();
    applyState(0);
    startPing();
  }

  // User scripts run before <body> exists; documentElement usually does, but
  // do not bet the whole UI on it.
  if (document.documentElement) {
    start();
  } else {
    var wait = setInterval(function () {
      if (document.documentElement) {
        clearInterval(wait);
        start();
      }
    }, 10);
  }
})();
