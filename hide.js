// Per-channel element hiding.
//
// Some sites put their own chrome around the player — Amazon's store header
// above Prime Video, say — that this app has no use for. A channel can list CSS
// selectors under `hide` in channels.yaml; any page on that channel's host
// gets them set to display:none.
//
// Matched by host, not full URL, so the rules also hold after navigating
// within the site (a title page, a player). Rules are applied through a
// constructed stylesheet where possible, which a page's CSP cannot block the
// way it can an inline <style>.

(function () {
  "use strict";

  if (window.__wvHideInstalled) return;
  window.__wvHideInstalled = true;

  function host(u) {
    try {
      return new URL(u).hostname.replace(/^www\./, "");
    } catch (e) {
      return "";
    }
  }

  var here = host(location.href);
  if (!here) return;

  var selectors = [];
  var channels = (window.__WV_BOOT || {}).channels || [];
  for (var i = 0; i < channels.length; i++) {
    if (host(channels[i].url) === here) {
      selectors = selectors.concat(channels[i].hide || []);
    }
  }
  if (!selectors.length) return;

  var css = selectors.join(",\n") + " { display: none !important; }";

  try {
    var sheet = new CSSStyleSheet();
    sheet.replaceSync(css);
    document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
    return;
  } catch (e) {
    // Older WebKit: fall back to a <style> element.
  }

  var style = document.createElement("style");
  style.textContent = css;
  (document.head || document.documentElement).appendChild(style);
})();
