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
  var open = false;
  var current = "";
  var host, wrap, toggle, list;

  var CSS = [
    ":host { all: initial; }",
    "* { box-sizing: border-box; margin: 0; padding: 0; }",

    ".toggle {",
    "  position: fixed; top: 10px; left: 10px;",
    "  width: 36px; height: 36px;",
    "  display: flex; align-items: center; justify-content: center;",
    "  font: 15px/1 -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;",
    "  color: #e9e9ee;",
    "  background: rgba(18,18,22,0.72);",
    "  border: 1px solid rgba(255,255,255,0.16);",
    "  border-radius: 9px;",
    "  -webkit-backdrop-filter: blur(10px); backdrop-filter: blur(10px);",
    "  cursor: pointer; opacity: 0.22; z-index: 2;",
    "  transition: opacity .18s ease, transform .24s cubic-bezier(.4,0,.2,1);",
    "}",
    // Idle-faded so it does not sit on top of video; wakes on hover or when open.
    ".toggle:hover, .wrap.open .toggle, .wrap.near .toggle { opacity: 1; }",
    ".wrap.open .toggle { transform: translateX(" + PANEL_WIDTH + "px); }",

    ".panel {",
    "  position: fixed; top: 0; left: 0;",
    "  width: " + PANEL_WIDTH + "px; height: 100vh;",
    "  display: flex; flex-direction: column;",
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
    "  padding: 16px 16px 10px 58px;",
    "  font-size: 11px; font-weight: 600;",
    "  letter-spacing: .09em; text-transform: uppercase;",
    "  color: rgba(233,233,238,0.45);",
    "}",

    ".list { flex: 1; overflow-y: auto; padding: 4px 8px 8px; list-style: none; }",
    ".list::-webkit-scrollbar { width: 8px; }",
    ".list::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.14); border-radius: 4px; }",

    ".item {",
    "  display: block; width: 100%; text-align: left;",
    "  padding: 9px 12px; margin-bottom: 2px;",
    "  font: inherit; color: #e9e9ee;",
    "  background: none; border: 0; border-radius: 7px;",
    "  cursor: pointer; position: relative;",
    "  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;",
    "  transition: background .12s ease;",
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
    ".foot kbd {",
    "  font: inherit; padding: 1px 5px;",
    "  background: rgba(255,255,255,0.1); border-radius: 4px;",
    "}"
  ].join("\n");

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

    toggle = document.createElement("button");
    toggle.className = "toggle";
    toggle.type = "button";
    toggle.title = "Channels (F9)";
    toggle.textContent = "☰";
    toggle.addEventListener("click", function () {
      setOpen(!open, true);
    });

    var panel = document.createElement("nav");
    panel.className = "panel";

    var head = document.createElement("div");
    head.className = "head";
    head.textContent = "Channels";

    list = document.createElement("ul");
    list.className = "list";

    var foot = document.createElement("div");
    foot.className = "foot";
    foot.innerHTML = "<kbd>F9</kbd> toggle · <kbd>Esc</kbd> close";

    panel.appendChild(head);
    panel.appendChild(list);
    panel.appendChild(foot);
    wrap.appendChild(toggle);
    wrap.appendChild(panel);
    root.appendChild(style);
    root.appendChild(wrap);

    renderList();
    document.documentElement.appendChild(host);
  }

  function renderList() {
    list.textContent = "";
    channels.forEach(function (ch) {
      var li = document.createElement("li");
      var btn = document.createElement("button");
      btn.className = "item" + (ch.url === current ? " active" : "");
      btn.type = "button";
      btn.textContent = ch.title;
      btn.title = ch.url;
      btn.addEventListener("click", function () {
        select(ch.url);
      });
      li.appendChild(btn);
      list.appendChild(li);
    });
  }

  function setOpen(next, notify) {
    open = !!next;
    wrap.classList.toggle("open", open);
    toggle.textContent = open ? "✕" : "☰";
    toggle.setAttribute("aria-expanded", open ? "true" : "false");
    if (notify && window.wvSetOpen) window.wvSetOpen(open);
  }

  function select(url) {
    current = url;
    renderList();
    if (window.wvSelect) window.wvSelect(url);
  }

  // The menubar's way in. setOpen notifies Go, so a.open stays in step exactly
  // as it does for F9. The guard matters: this is reachable from the menu the
  // moment the script runs, which can be before build() has made `wrap`.
  window.wvToggleSidebar = function () {
    if (wrap) setOpen(!open, true);
  };

  // Wake the toggle button when the pointer approaches the left edge, so it
  // stays discoverable without permanently covering the page.
  function trackEdge() {
    window.addEventListener(
      "mousemove",
      function (e) {
        wrap.classList.toggle("near", e.clientX < 90 && e.clientY < 160);
      },
      true
    );
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
        current = state.current || "";
        renderList();
        setOpen(!!state.open, false);
        releaseAnimations();
      },
      releaseAnimations
    );
  }

  function releaseAnimations() {
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        wrap.classList.remove("no-anim");
      });
    });
  }

  function start() {
    build();
    trackEdge();
    bindKeys();
    keepAttached();
    applyState(0);
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
