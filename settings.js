// Settings panel: edit the channel list and the global settings.
//
// Injected into every page like sidebar.js, but it builds nothing until
// window.wvOpenSettings() is called (the sidebar's footer button, or Cmd-, from
// the menu), so a page that never opens it pays for one function.
//
// Everything native sits behind two calls, so a host that provides them gets
// the whole panel unchanged:
//
//   window.wvGetConfig()      -> {config, defaultUserAgent, regions, raw, path, warnings}
//   window.wvSaveConfig(json) -> {ok, error, warnings, restart}
//                                json is '{"config": {...}}' or '{"raw": "..."}'
//
// The panel never sees a file path for a VPN region, only its name and
// whether its file is there, so it cannot send one back.
//
// Optional, provided by sidebar.js: window.wvConfigChanged(), called after a
// save so the sidebar list picks the new channels up without a page load.

(function () {
  "use strict";

  // Ad frames and embeds must not each grow a settings panel.
  if (window.top !== window.self) return;
  if (window.__wvSettingsInstalled) return;
  window.__wvSettingsInstalled = true;

  var CSS = [
    ":host { all: initial; }",
    "* { box-sizing: border-box; }",
    ".scrim {",
    "  position: fixed; inset: 0; display: flex; align-items: center; justify-content: center;",
    "  padding: calc(16px + var(--st, 0px)) calc(16px + var(--sr, 0px)) calc(16px + var(--sb, 0px)) calc(16px + var(--sl, 0px));",
    "  background: rgba(0,0,0,0.55);",
    "  -webkit-backdrop-filter: blur(4px); backdrop-filter: blur(4px);",
    "  font: 13px/1.4 -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;",
    "  color: #e9e9ee;",
    "}",
    ".dlg {",
    "  display: flex; flex-direction: column;",
    "  width: min(820px, 100%); height: min(760px, 100%);",
    "  background: rgba(22,22,28,0.98);",
    "  border: 1px solid rgba(255,255,255,0.14); border-radius: 12px;",
    "  box-shadow: 0 18px 60px rgba(0,0,0,0.65); overflow: hidden;",
    "}",
    ".top {",
    "  display: flex; align-items: center; gap: 4px; padding: 10px 12px 0;",
    "  border-bottom: 1px solid rgba(255,255,255,0.1);",
    "}",
    ".tabs { display: flex; }",
    ".top h1 { font-size: 14px; font-weight: 600; margin: 0 14px 0 6px; padding-bottom: 8px; }",
    ".tab {",
    "  font: inherit; color: rgba(233,233,238,0.6); background: none; border: 0;",
    "  border-bottom: 2px solid transparent; padding: 8px 12px; cursor: pointer;",
    "}",
    ".tab:hover { color: #e9e9ee; }",
    ".tab.on { color: #e9e9ee; border-bottom-color: #5b9dff; }",
    ".body { flex: 1; overflow-y: auto; padding: 14px 16px; }",
    ".body::-webkit-scrollbar { width: 8px; }",
    ".body::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.14); border-radius: 4px; }",

    ".card {",
    "  margin-bottom: 10px; padding: 10px;",
    "  background: rgba(255,255,255,0.04);",
    "  border: 1px solid rgba(255,255,255,0.09); border-radius: 9px;",
    "}",
    ".row { display: flex; align-items: center; gap: 8px; }",
    ".row + .row, .row + .grid, .grid + .row { margin-top: 8px; }",
    ".grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }",
    "@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }",
    ".grip {",
    "  flex: none; width: 18px; text-align: center; font-size: 17px; line-height: 1;",
    "  color: rgba(233,233,238,0.4); cursor: grab; user-select: none; -webkit-user-select: none;",
    "  touch-action: none;",
    "}",
    ".grip:hover { color: #e9e9ee; }",
    ".card.drag {",
    "  position: relative; z-index: 2; cursor: grabbing;",
    "  background: rgba(60,60,76,0.98); border-color: #5b9dff;",
    "  box-shadow: 0 8px 28px rgba(0,0,0,0.55);",
    "}",
    ".spacer { flex: none; width: 18px; }",
    ".toast {",
    "  position: fixed; left: 50%; bottom: calc(24px + var(--sb, 0px)); transform: translateX(-50%);",
    "  max-width: min(560px, calc(100% - 32px)); padding: 10px 16px;",
    "  font: 13px/1.4 -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;",
    "  color: #e9e9ee; background: rgba(40,40,50,0.97);",
    "  border: 1px solid rgba(255,255,255,0.18); border-radius: 10px;",
    "  box-shadow: 0 10px 40px rgba(0,0,0,0.6); cursor: pointer;",
    "}",
    ".toast div { margin: 2px 0; overflow-wrap: anywhere; }",
    ".toast .ok { color: #8fe0a6; }",
    ".toast .warn { color: #ffd68a; }",
    ".toast .note { color: rgba(233,233,238,0.7); }",
    ".num { flex: none; width: 24px; text-align: right; color: rgba(233,233,238,0.4); font-size: 12px; }",

    "label.f { display: block; }",
    "label.f > span {",
    "  display: block; margin-bottom: 3px;",
    "  font-size: 11px; font-weight: 600; letter-spacing: .05em; text-transform: uppercase;",
    "  color: rgba(233,233,238,0.45);",
    "}",
    "input[type=text], input[type=number], textarea, select {",
    "  width: 100%; min-height: 34px; padding: 6px 9px;",
    "  font: inherit; color: #e9e9ee;",
    "  background: rgba(255,255,255,0.06);",
    "  border: 1px solid rgba(255,255,255,0.14); border-radius: 6px;",
    "}",
    "textarea { resize: vertical; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }",
    "input:focus, textarea:focus, select:focus { outline: none; border-color: #5b9dff; }",
    "input[type=checkbox] { width: 16px; height: 16px; accent-color: #5b9dff; }",
    ".check { display: flex; align-items: center; gap: 8px; min-height: 34px; }",

    "button.b {",
    "  font: inherit; color: #e9e9ee; min-height: 34px; min-width: 34px; padding: 0 12px;",
    "  background: rgba(255,255,255,0.08);",
    "  border: 1px solid rgba(255,255,255,0.16); border-radius: 7px; cursor: pointer;",
    "}",
    "button.b:hover:not(:disabled) { background: rgba(255,255,255,0.15); }",
    "button.b:disabled { opacity: 0.35; cursor: default; }",
    "button.b.pri { background: #3b7be0; border-color: #3b7be0; color: #fff; }",
    "button.b.pri:hover:not(:disabled) { background: #4d8cf0; }",
    "button.b.danger:hover:not(:disabled) { background: rgba(255,90,80,0.28); border-color: rgba(255,120,110,0.6); }",
    "button.b.sm { padding: 0; }",

    ".foot {",
    "  display: flex; align-items: flex-start; gap: 12px; padding: 10px 16px;",
    "  border-top: 1px solid rgba(255,255,255,0.1);",
    "}",
    ".msgs { flex: 1; min-width: 0; font-size: 12px; max-height: 96px; overflow-y: auto; }",
    ".msgs div { margin-bottom: 2px; overflow-wrap: anywhere; }",
    ".msgs .ok { color: #8fe0a6; }",
    ".msgs .err { color: #ffa59c; }",
    ".msgs .warn { color: #ffd68a; }",
    ".msgs .note { color: rgba(233,233,238,0.55); }",
    ".btns { display: flex; gap: 8px; flex: none; }",

    ".hint { font-size: 12px; color: rgba(233,233,238,0.5); margin: 4px 0 10px; }",
    ".sec { font-size: 11px; font-weight: 600; letter-spacing: .09em; text-transform: uppercase;",
    "  color: rgba(233,233,238,0.45); margin: 18px 0 8px; }",
    ".sec:first-child { margin-top: 0; }",
    ".chip { display: inline-block; margin: 0 6px 6px 0; padding: 3px 9px; border-radius: 12px;",
    "  font-size: 12px; background: rgba(255,255,255,0.08); }",
    ".chip.ok::before { content: '\\2713  '; color: #8fe0a6; }",
    ".chip.pending, .chip.missing { background: rgba(255,200,90,0.14); color: #ffd68a; }",
    ".chip.pending::before, .chip.missing::before { content: '\\26A0  '; }",
    ".raw { min-height: 100%; height: 100%; white-space: pre; tab-size: 2; }"
  ].join("\n");

  var host = null;
  var list; // the channel cards container, so cards are list.children[i]
  var root, dlg, body, msgs, saveBtn, applyBtn, closeBtn, tabsEl, scrim, datalist;
  var model = null; // what native last said: config, regions, raw, ...
  var draft = null; // the panel's editable copy of model.config
  var baseline = ""; // JSON of draft as loaded, to tell if anything changed
  var rawText = "";
  var rawBase = "";
  var tab = "channels";
  var closing = false; // a dirty close has been asked for once already

  // Keys typed in the panel must not reach the page, not even in the capture phase: a
  // TV-style page (YouTube's /tv) takes every key on window and cancels it, which leaves
  // the fields uneditable. This listener goes in at document start, ahead of the page's,
  // and stops the event there; the default action (typing) is left alone.
  ["keydown", "keyup", "keypress"].forEach(function (type) {
    window.addEventListener(type, function (e) {
      if (!host) return;
      if (type === "keydown" && e.key === "Escape") {
        e.preventDefault();
        e.stopImmediatePropagation();
        close();
      } else if (e.composedPath().indexOf(host) >= 0) {
        e.stopImmediatePropagation();
      }
    }, true);
  });

  // ---- tiny DOM helper ----------------------------------------------------
  // Not innerHTML: pages that enforce Trusted Types throw on it.
  function el(tag, props, kids) {
    var e = document.createElement(tag);
    props = props || {};
    for (var k in props) {
      if (k === "text") e.textContent = props[k];
      else if (k === "cls") e.className = props[k];
      else if (k.slice(0, 2) === "on") e.addEventListener(k.slice(2), props[k]);
      else if (k === "value") e.value = props[k];
      else if (props[k] === true) e.setAttribute(k, "");
      else if (props[k] !== false && props[k] != null) e.setAttribute(k, props[k]);
    }
    (kids || []).forEach(function (c) {
      if (c) e.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    });
    return e;
  }

  function field(label, input) {
    return el("label", { cls: "f" }, [el("span", { text: label }), input]);
  }

  function clone(o) {
    return JSON.parse(JSON.stringify(o));
  }

  // ---- model <-> draft ----------------------------------------------------
  function toDraft(cfg) {
    var d = clone(cfg);
    d.channels = (d.channels || []).map(function (c) {
      return {
        title: c.title || "",
        url: c.url || "",
        region: c.region || "",
        hide: (c.hide || []).join("\n"),
        user_agent: c.user_agent || ""
      };
    });
    d.window = d.window || {};
    d.media = d.media || {};
    d.user_agent = d.user_agent || "";
    return d;
  }

  // The shape native expects: numbers as numbers, hide as a list, blanks gone.
  function toConfig(d) {
    return {
      window: {
        title: d.window.title,
        width: parseInt(d.window.width, 10) || 0,
        height: parseInt(d.window.height, 10) || 0
      },
      media: {
        seekSeconds: parseInt(d.media.seekSeconds, 10) || 0,
        reverse: !!d.media.reverse
      },
      user_agent: (d.user_agent || "").trim(),
      channels: d.channels.map(function (c) {
        return {
          title: c.title.trim(),
          url: c.url.trim(),
          region: c.region.trim(),
          hide: c.hide
            .split("\n")
            .map(function (s) { return s.trim(); })
            .filter(Boolean),
          user_agent: (c.user_agent || "").trim()
        };
      })
    };
  }

  function structDirty() {
    return !!draft && JSON.stringify(draft) !== baseline;
  }
  function rawDirty() {
    return rawText !== rawBase;
  }
  function dirty() {
    return structDirty() || rawDirty();
  }

  // Reasons the draft cannot be saved, in words. Native checks again; this is
  // so the common mistakes are caught before a round trip.
  function problems() {
    var out = [];
    draft.channels.forEach(function (c, i) {
      var n = "Channel " + (i + 1) + (c.title.trim() ? " (" + c.title.trim() + ")" : "");
      if (!c.url.trim()) out.push(n + " has no URL.");
      else if (!/^https?:\/\//i.test(c.url.trim())) out.push(n + ": the URL should start with http:// or https://.");
    });
    if (!draft.channels.length) out.push("Add at least one channel.");
    if (!(parseInt(draft.window.width, 10) > 0) || !(parseInt(draft.window.height, 10) > 0)) {
      out.push("Window width and height must be positive numbers.");
    }
    if (!(parseInt(draft.media.seekSeconds, 10) > 0)) out.push("Seek seconds must be a positive number.");
    return out;
  }

  // ---- messages -----------------------------------------------------------
  function say(items) {
    msgs.textContent = "";
    items.forEach(function (it) {
      msgs.appendChild(el("div", { cls: it[0], text: it[1] }));
    });
  }

  function baseMessages() {
    var items = [];
    if (model) {
      (model.warnings || []).forEach(function (w) { items.push(["warn", w]); });
      if (!items.length) items.push(["note", "Saves to " + model.path]);
    }
    return items;
  }

  // ---- tabs ---------------------------------------------------------------
  function renderTabs() {
    tabsEl.textContent = "";
    [["channels", "Channels"], ["general", "General"], ["raw", "Raw YAML"]].forEach(function (t) {
      tabsEl.appendChild(
        el("button", {
          cls: "tab" + (tab === t[0] ? " on" : ""),
          type: "button",
          text: t[1],
          onclick: function () {
            tab = t[0];
            closing = false;
            render();
          }
        })
      );
    });
  }

  function render() {
    var keep = body.scrollTop;
    renderTabs();
    body.textContent = "";
    if (tab === "channels") renderChannels();
    else if (tab === "general") renderGeneral();
    else renderRaw();
    body.scrollTop = keep;
    refreshButtons();
  }

  function refreshButtons() {
    saveBtn.disabled = applyBtn.disabled = tab === "raw" ? !rawDirty() : !structDirty();
    closeBtn.textContent = closing && dirty() ? "Discard changes?" : dirty() ? "Cancel" : "Close";
    closeBtn.classList.toggle("danger", closing && dirty());
  }

  function touched() {
    closing = false;
    refreshButtons();
  }

  // ---- channels tab -------------------------------------------------------
  // After the swap the card is somewhere else on the screen, and the button
  // that was just clicked is now on its neighbour. Scroll so the moved card
  // ends up where it was under the pointer, so the same button can be clicked
  // again, and put keyboard focus on the same button too.
  function move(i, d, which) {
    var j = i + d;
    if (j < 0 || j >= draft.channels.length) return;
    var before = list.children[i].getBoundingClientRect().top;
    var t = draft.channels[i];
    draft.channels[i] = draft.channels[j];
    draft.channels[j] = t;
    touched();
    render();
    var card = list.children[j];
    body.scrollTop += card.getBoundingClientRect().top - before;
    var b = card.querySelectorAll(".mv")[which];
    if (b && !b.disabled) b.focus({ preventScroll: true });
    else {
      var other = card.querySelectorAll(".mv")[1 - which];
      if (other && !other.disabled) other.focus({ preventScroll: true });
    }
  }

  // Drag by the grip. Pointer events, so touch works too. The dragged card
  // follows the pointer by transform, and swaps places in the list (and the
  // draft) as its centre crosses a neighbour's; the page scrolls when the
  // pointer nears the top or bottom edge.
  function startDrag(e, card, c) {
    if (e.button != null && e.button !== 0) return;
    e.preventDefault();
    var grip = e.currentTarget;
    try { grip.setPointerCapture(e.pointerId); } catch (err) {}
    card.classList.add("drag");

    var startY = e.clientY;
    var lastY = e.clientY;
    var raf = 0;

    function place() {
      card.style.transform = "translateY(" + (lastY - startY) + "px)";
      var r, mid, sib;
      for (;;) {
        r = card.getBoundingClientRect();
        mid = r.top + r.height / 2;
        sib = card.nextElementSibling;
        if (sib && sib.classList.contains("card")) {
          var s = sib.getBoundingClientRect();
          if (mid > s.top + s.height / 2) {
            var shift = s.height + 10; // card height plus its margin
            list.insertBefore(sib, card);
            swapDraft(c, 1);
            startY += shift;
            card.style.transform = "translateY(" + (lastY - startY) + "px)";
            continue;
          }
        }
        sib = card.previousElementSibling;
        if (sib && sib.classList.contains("card")) {
          var p = sib.getBoundingClientRect();
          if (mid < p.top + p.height / 2) {
            var back = p.height + 10;
            list.insertBefore(card, sib);
            swapDraft(c, -1);
            startY -= back;
            card.style.transform = "translateY(" + (lastY - startY) + "px)";
            continue;
          }
        }
        break;
      }
    }

    function swapDraft(item, d) {
      var i = draft.channels.indexOf(item);
      draft.channels.splice(i, 1);
      draft.channels.splice(i + d, 0, item);
    }

    function scrollTick() {
      var b = body.getBoundingClientRect();
      var v = 0;
      if (lastY < b.top + 48) v = -Math.ceil((b.top + 48 - lastY) / 4);
      else if (lastY > b.bottom - 48) v = Math.ceil((lastY - (b.bottom - 48)) / 4);
      if (v) {
        var was = body.scrollTop;
        body.scrollTop += v;
        startY -= body.scrollTop - was; // the card stays under the pointer
        place();
      }
      raf = requestAnimationFrame(scrollTick);
    }

    function onMove(ev) {
      lastY = ev.clientY;
      place();
    }
    function end() {
      cancelAnimationFrame(raf);
      window.removeEventListener("pointermove", onMove, true);
      window.removeEventListener("pointerup", end, true);
      window.removeEventListener("pointercancel", end, true);
      card.classList.remove("drag");
      card.style.transform = "";
      touched();
      render(); // renumber, and re-aim the arrow buttons at the new indexes
    }
    // On window rather than the grip: capture can be refused (and the page
    // may be moving things under us), and the drag must still end.
    window.addEventListener("pointermove", onMove, true);
    window.addEventListener("pointerup", end, true);
    window.addEventListener("pointercancel", end, true);
    raf = requestAnimationFrame(scrollTick);
  }

  function renderChannels() {
    body.appendChild(
      el("div", {
        cls: "hint",
        text: "Order here is the order in the sidebar and the Channels menu. A region routes the channel through that VPN tunnel."
      })
    );

    datalist.textContent = "";
    (model.regions || []).forEach(function (r) {
      datalist.appendChild(el("option", { value: r.name }));
    });

    list = el("div", {});
    draft.channels.forEach(function (c, i) {
      var title = el("input", {
        type: "text", placeholder: "Title", value: c.title,
        oninput: function () { c.title = title.value; touched(); }
      });
      var url = el("input", {
        type: "text", placeholder: "https://…", value: c.url, autocapitalize: "off", spellcheck: "false",
        oninput: function () { c.url = url.value; touched(); }
      });
      var region = el("input", {
        type: "text", placeholder: "none", value: c.region, list: "regions", autocapitalize: "off", spellcheck: "false",
        oninput: function () { c.region = region.value; touched(); }
      });
      var hide = el("textarea", {
        rows: "2", placeholder: ".site-header\n#banner", value: c.hide, spellcheck: "false",
        oninput: function () { c.hide = hide.value; touched(); }
      });

      var cua = el("textarea", {
        rows: "2", placeholder: "default (the user agent above)", value: c.user_agent, spellcheck: "false",
        oninput: function () { c.user_agent = cua.value; touched(); }
      });

      var up = el("button", { cls: "b sm mv", type: "button", text: "↑", title: "Move up", onclick: function () { move(i, -1, 0); } });
      var down = el("button", { cls: "b sm mv", type: "button", text: "↓", title: "Move down", onclick: function () { move(i, 1, 1); } });
      up.disabled = i === 0;
      down.disabled = i === draft.channels.length - 1;
      var del = el("button", {
        cls: "b sm danger", type: "button", text: "✕", title: "Remove channel",
        onclick: function () {
          draft.channels.splice(i, 1);
          touched();
          render();
        }
      });

      var card = el("div", { cls: "card" }, [
        el("div", { cls: "row" }, [
          el("span", { cls: "grip", text: "\u283F", title: "Drag to reorder" }),
          el("span", { cls: "num", text: String(i + 1) }),
          title, up, down, del
        ]),
        el("div", { cls: "row" }, [el("span", { cls: "spacer" }), el("span", { cls: "num" }), url]),
        el("div", { cls: "grid" }, [
          field("Region (VPN)", region),
          field("Hide elements (CSS selectors, one per line)", hide),
          field("User agent (overrides the default for this channel)", cua)
        ])
      ]);
      card.querySelector(".grip").addEventListener("pointerdown", function (e) { startDrag(e, card, c); });
      list.appendChild(card);
    });
    body.appendChild(list);

    body.appendChild(
      el("button", {
        cls: "b", type: "button", text: "+ Add channel",
        onclick: function () {
          draft.channels.push({ title: "", url: "", region: "", hide: "", user_agent: "" });
          touched();
          render();
          body.scrollTop = body.scrollHeight;
        }
      })
    );
  }

  // ---- general tab --------------------------------------------------------
  function renderGeneral() {
    var d = draft;
    function num(obj, key, label, min) {
      var i = el("input", {
        type: "number", min: String(min), value: String(obj[key] == null ? "" : obj[key]),
        oninput: function () { obj[key] = i.value; touched(); }
      });
      return field(label, i);
    }

    body.appendChild(el("div", { cls: "sec", text: "Window" }));
    var wt = el("input", {
      type: "text", value: d.window.title || "",
      oninput: function () { d.window.title = wt.value; touched(); }
    });
    body.appendChild(el("div", { cls: "card" }, [
      field("Title", wt),
      el("div", { cls: "grid" }, [num(d.window, "width", "Width", 100), num(d.window, "height", "Height", 100)]),
      el("div", { cls: "hint", text: "The title applies now; the size on the next launch." })
    ]));

    body.appendChild(el("div", { cls: "sec", text: "Headphone previous / next" }));
    var rev = el("input", {
      type: "checkbox",
      onchange: function () { d.media.reverse = rev.checked; touched(); }
    });
    rev.checked = !!d.media.reverse;
    body.appendChild(el("div", { cls: "card" }, [
      num(d.media, "seekSeconds", "Seconds per press", 1),
      el("label", { cls: "check" }, [rev, "Swap previous and next (for headsets that report them backwards)"])
    ]));

    body.appendChild(el("div", { cls: "sec", text: "User agent" }));
    var ua = el("textarea", {
      rows: "3", value: d.user_agent || "", spellcheck: "false",
      oninput: function () { d.user_agent = ua.value; touched(); }
    });
    body.appendChild(el("div", { cls: "card" }, [
      ua,
      el("div", { cls: "row" }, [
        el("button", {
          cls: "b", type: "button", text: "Reset to default",
          onclick: function () {
            d.user_agent = model.defaultUserAgent;
            ua.value = d.user_agent;
            touched();
          }
        }),
        el("span", { cls: "hint", text: "What the web view tells sites it is. Applies from the next page load." })
      ])
    ]));

    body.appendChild(el("div", { cls: "sec", text: "VPN regions" }));
    var chips = el("div", {});
    (model.regions || []).forEach(function (r) {
      chips.appendChild(el("span", { cls: "chip " + r.state, text: r.name, title: stateTitle(r.state) }));
    });
    if (!(model.regions || []).length) chips.appendChild(el("span", { cls: "hint", text: "None configured." }));
    body.appendChild(el("div", { cls: "card" }, [
      chips,
      el("div", {
        cls: "hint",
        text: "A region is a WireGuard file in the wireguard folder next to the config, named REGION.conf. " +
          "Type a new region on a channel and save to reserve it, then add the file."
      })
    ]));
  }

  function stateTitle(s) {
    return s === "ok" ? "File found" : s === "pending" ? "Waiting for its .conf file" : "Listed, but its file is missing";
  }

  // ---- raw tab ------------------------------------------------------------
  function renderRaw() {
    if (structDirty()) {
      body.appendChild(el("div", {
        cls: "hint",
        text: "Unsaved edits on the other tabs are not part of this text. Save them first, or they will be replaced when this saves."
      }));
    }
    var ta = el("textarea", {
      cls: "raw", value: rawText, spellcheck: "false", wrap: "off",
      oninput: function () { rawText = ta.value; touched(); }
    });
    body.appendChild(ta);
  }

  // ---- load / save --------------------------------------------------------
  function load(then) {
    Promise.resolve(window.wvGetConfig()).then(function (m) {
      model = m;
      draft = toDraft(m.config);
      baseline = JSON.stringify(draft);
      rawText = rawBase = m.raw || "";
      then();
    }, function (e) {
      say([["err", "Could not read the configuration: " + e]]);
    });
  }

  // Save writes and closes; Apply writes and stays. Either way a failure keeps
  // the panel open with the reason, and nothing is lost.
  function save(andClose) {
    var payload;
    if (tab === "raw") {
      payload = { raw: rawText };
    } else {
      var bad = problems();
      if (bad.length) {
        say(bad.map(function (b) { return ["err", b]; }));
        return;
      }
      payload = { config: toConfig(draft) };
    }
    saveBtn.disabled = applyBtn.disabled = true;
    say([["note", "Saving…"]]);

    Promise.resolve(window.wvSaveConfig(JSON.stringify(payload))).then(function (res) {
      if (!res || !res.ok) {
        say([["err", (res && res.error) || "Save failed."]]);
        refreshButtons();
        return;
      }
      var items = [["ok", "Saved."]];
      (res.warnings || []).forEach(function (w) { items.push(["warn", w]); });
      if ((res.restart || []).length) {
        items.push(["note", "Restart to apply: " + res.restart.join(", ") + "."]);
      }
      if (andClose) {
        // Closing hides the footer these notes would have gone to, so they
        // go to a toast instead.
        teardown(items);
        if (window.wvConfigChanged) window.wvConfigChanged();
        return;
      }
      // Reload so what is shown is what the app now holds, defaults and
      // reconciled VPN entries included.
      load(function () {
        closing = false;
        render();
        say(items);
        if (window.wvConfigChanged) window.wvConfigChanged();
      });
    }, function (e) {
      say([["err", "Save failed: " + e]]);
      refreshButtons();
    });
  }

  function close() {
    if (dirty() && !closing) {
      closing = true;
      refreshButtons();
      say([["warn", "There are unsaved changes. Press again to discard them."]]);
      return;
    }
    teardown();
  }

  // ---- lifecycle ----------------------------------------------------------
  function build() {
    host = el("div", { id: "__wv_settings" });
    host.setAttribute("style", "all: initial; position: fixed; top: 0; left: 0; width: 0; height: 0; z-index: 2147483647;");
    root = host.attachShadow({ mode: "open" });

    tabsEl = el("div", { cls: "tabs" });
    body = el("div", { cls: "body" });
    msgs = el("div", { cls: "msgs" });
    datalist = el("datalist", { id: "regions" });
    applyBtn = el("button", { cls: "b", type: "button", text: "Apply", title: "Save and keep editing", onclick: function () { save(false); } });
    saveBtn = el("button", { cls: "b pri", type: "button", text: "Save", title: "Save and close", onclick: function () { save(true); } });
    closeBtn = el("button", { cls: "b", type: "button", text: "Close", onclick: close });

    dlg = el("div", { cls: "dlg", role: "dialog", "aria-label": "Settings" }, [
      el("div", { cls: "top" }, [el("h1", { text: "Settings" }), tabsEl]),
      body,
      el("div", { cls: "foot" }, [msgs, el("div", { cls: "btns" }, [closeBtn, applyBtn, saveBtn])]),
      datalist
    ]);
    scrim = el("div", { cls: "scrim" }, [dlg]);

    // Keystrokes typed here must not reach the page's own shortcuts (space,
    // f, arrows on a player). Stopped at the host, in the bubble phase; a
    // page that listens in the capture phase on window still sees them.
    ["keydown", "keyup", "keypress"].forEach(function (t) {
      host.addEventListener(t, function (e) { e.stopPropagation(); });
    });

    root.appendChild(el("style", { text: CSS }));
    root.appendChild(scrim);
    document.documentElement.appendChild(host);
    if (window.__wvFitViewport) window.__wvFitViewport(host);
    if (window.__wvApplySafe) window.__wvApplySafe(host);

  }

  // Closes the dialog. With notes, leaves the host up a few seconds to show
  // them in a toast (a click dismisses it; it stays longer when there is
  // something to act on).
  function teardown(notes) {
    model = draft = null;
    var gone = host;
    if (!gone) return;
    host = null;
    var remove = function () {
      if (gone.parentNode) gone.parentNode.removeChild(gone);
    };
    if (!notes || !notes.length) return remove();

    scrim.parentNode.removeChild(scrim);
    var toast = el("div", { cls: "toast", title: "Click to dismiss" });
    notes.forEach(function (n) { toast.appendChild(el("div", { cls: n[0], text: n[1] })); });
    toast.addEventListener("click", remove);
    root.appendChild(toast);
    setTimeout(remove, notes.length > 1 ? 9000 : 3000);
  }

  window.wvOpenSettings = function () {
    if (host) return;
    if (!window.wvGetConfig || !window.wvSaveConfig) return;
    tab = "channels";
    closing = false;
    build();
    say([["note", "Loading…"]]);
    load(function () {
      render();
      say(baseMessages());
    });
  };
})();
