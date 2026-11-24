// The iOS 17.3 style fix, loaded into claude.ai by the Claude Web app (see PageScripts.styleFix).
//
// WebKit in iOS 17.3 crashes on two things in claude.ai's CSS:
//  1. Relative colour syntax, such as rgb(from red r g b) in an @supports test
//     (crash in RenderThemeIOS::systemColor while parsing the style sheet).
//  2. :has() selectors that test an attribute, such as :has([data-state=open]), which WebKit
//     re-checks after the page changes (crash in HTMLDocument::isCaseSensitiveAttribute).
//
// The app's content rule list (StyleFixRules) stops WebKit from loading style sheets from Claude's
// own servers, so it never parses the originals. This script loads each of those sheets itself,
// renames every relative colour and every attribute-testing :has() to something WebKit treats as
// unsupported, and adds the result to the page right where the <link> is. The link's blocked
// "error" is kept from the page, which gets "load" instead once the copy is in place. Style sheets
// the page preloads (<link rel="preload" as="style">) are blocked too, and answered the same way.
//
// Before this runs, the app sets window.__claudeStyleFixHost (PageScripts.styleFixHost):
//   fetchText(url) -> Promise<string>   downloads a sheet the page itself isn't allowed to read
//   report(message)                     receives { fixed, count, hasCount, how } | { failed, error } | { seen }

(function () {
  if (window.top !== window || window.__claudeWebStyleFix) return;
  window.__claudeWebStyleFix = true;

  // Keep in step with StyleFixRules.hosts in the app.
  var OWN_HOST = /(^|\.)(claude\.ai|claude\.com|anthropic\.com)$/i;
  var RELATIVE_COLOR = /\b(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(\s*from\s/gi;
  // What the app provides (see the top of this file).
  var host = window.__claudeStyleFixHost || {};

  function report(message) {
    try { if (host.report) host.report(message); } catch (e) {}
  }

  // "stylesheet", "preload" or "prefetch" for a <link> to a style sheet; "" for anything else.
  function linkKind(node) {
    if (!node || node.nodeName !== "LINK") return "";
    var rel = (node.getAttribute("rel") || "").toLowerCase();
    if (/(^|\s)stylesheet(\s|$)/.test(rel)) return "stylesheet";
    var isStyle = (node.getAttribute("as") || "").toLowerCase() === "style" ||
      /\.css([?#]|$)/i.test(node.getAttribute("href") || "");
    if (isStyle && /(^|\s)preload(\s|$)/.test(rel)) return "preload";
    if (isStyle && /(^|\s)prefetch(\s|$)/.test(rel)) return "prefetch";
    return "";
  }

  function isStyleSheetLink(node) {
    return linkKind(node) === "stylesheet";
  }

  function ownURL(link) {
    try {
      var url = new URL(link.getAttribute("href") || "", document.baseURI);
      return url.protocol === "https:" && OWN_HOST.test(url.hostname) ? url : null;
    } catch (e) {
      return null;
    }
  }

  // The app blocks the original download, so the link fires "error". Keep that from the page; it gets
  // "load" (or a real "error") once the copy is in place. A preload gets "load" once the file is
  // ready here, so code that turns it into a style sheet on load carries on. Nothing waits on a prefetch.
  window.addEventListener("error", function (event) {
    var link = event.target;
    var kind = linkKind(link);
    if (!kind || link.__claudeWebDispatching || !ownURL(link)) return;
    event.stopImmediatePropagation();
    if (kind === "stylesheet") takeOver(link);
    else if (kind === "preload") answerPreload(link);
  }, true);

  // Keep the page hidden while its first style sheets load, instead of flashing it unstyled.
  var waiting = 0, safety = null;
  function hide() {
    waiting += 1;
    if (waiting === 1) {
      document.documentElement.style.setProperty("visibility", "hidden", "important");
      safety = setTimeout(function () { waiting = 1; show(); }, 6000);
    }
  }
  function show() {
    waiting = Math.max(0, waiting - 1);
    if (waiting === 0) {
      clearTimeout(safety);
      document.documentElement.style.removeProperty("visibility");
    }
  }

  // One download per file, shared by a preload and the style sheet that follows it.
  var texts = {};
  function getText(href) {
    if (!texts[href]) {
      texts[href] = download(href).catch(function (error) {
        delete texts[href];
        throw error;
      });
    }
    return texts[href];
  }

  function download(href) {
    return fetch(href, { credentials: "same-origin", cache: "force-cache" })
      .then(function (response) {
        if (!response.ok) throw new Error("HTTP " + response.status);
        return response.text();
      })
      .catch(function (error) {
        // The page isn't allowed to read it (no CORS headers): the app or extension fetches it instead.
        if (!host.fetchText) throw error;
        return host.fetchText(href);
      });
  }

  function absolute(path, base) {
    if (/^([a-z][a-z0-9+.-]*:|\/\/|#)/i.test(path)) return path;
    try { return new URL(path, base).href; } catch (e) { return path; }
  }

  // Second iOS 17.3 crash: after the page changes, WebKit re-checks :has() selectors, and crashes
  // (in HTMLDocument::isCaseSensitiveAttribute) on ones that test an attribute, such as
  // :has([data-state=open]). Rename just those so WebKit drops them, as a browser without :has()
  // would; other :has() selectors are left alone.
  function disableAttributeHas(css) {
    var lower = css.toLowerCase();
    var out = "", from = 0, count = 0;
    for (;;) {
      var at = lower.indexOf(":has(", from);
      if (at < 0) break;
      var depth = 0, quote = "", end = -1;
      for (var i = at + 4; i < css.length; i++) {
        var ch = css.charAt(i);
        if (quote) {
          if (ch === "\\") i++;
          else if (ch === quote) quote = "";
        } else if (ch === "\"" || ch === "'") {
          quote = ch;
        } else if (ch === "(") {
          depth++;
        } else if (ch === ")" && --depth === 0) {
          end = i;
          break;
        }
      }
      if (end < 0) break;  // unbalanced: leave the rest as it is
      var testsAttribute = css.slice(at + 5, end).indexOf("[") >= 0;
      out += css.slice(from, at) + (testsAttribute ? ":-claude-web-unsupported-has(" : css.slice(at, at + 5));
      if (testsAttribute) count++;
      from = at + 5;
    }
    disableAttributeHas.count = count;
    return out + css.slice(from);
  }

  function fix(css, base) {
    css = css.replace(RELATIVE_COLOR, function (match, name) {
      return "-claude-web-unsupported-" + name + "(from ";
    });
    css = disableAttributeHas(css);
    // Paths inside the file were relative to it; it now lives in the page, so make them absolute.
    css = css.replace(/url\(\s*(['"]?)([^'")\s]+)\1\s*\)/gi, function (match, quote, path) {
      return "url(" + quote + absolute(path, base) + quote + ")";
    });
    return css.replace(/@import\s+(['"])([^'"]+)\1/gi, function (match, quote, path) {
      return "@import " + quote + absolute(path, base) + quote;
    });
  }

  function pageNonce() {
    var element = document.querySelector("style[nonce], script[nonce]");
    return element ? (element.nonce || element.getAttribute("nonce") || "") : "";
  }

  function insert(link, css) {
    var style = document.createElement("style");
    style.setAttribute("data-claude-web-fixed", link.href);
    var media = link.getAttribute("media");
    if (media) style.setAttribute("media", media);
    var nonce = link.nonce || pageNonce();
    if (nonce) style.setAttribute("nonce", nonce);
    style.textContent = css;
    if (link.parentNode) {
      link.parentNode.insertBefore(style, link.nextSibling);
    } else {
      (document.head || document.documentElement).appendChild(style);
    }
    if (style.sheet) return "style";
    // The page's Content Security Policy refused the <style>; constructed sheets aren't subject to it.
    style.remove();
    var sheet = new CSSStyleSheet(media ? { media: media } : undefined);
    sheet.replaceSync(css);
    document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
    return "constructed";
  }

  function dispatch(link, type) {
    link.__claudeWebDispatching = true;
    try { link.dispatchEvent(new Event(type)); } finally { link.__claudeWebDispatching = false; }
  }

  function answerPreload(link) {
    if (link.__claudeWebPreload) return;
    link.__claudeWebPreload = true;
    getText(ownURL(link).href).then(function () {
      dispatch(link, "load");
    }, function () {
      dispatch(link, "error");
    });
  }

  function takeOver(link) {
    if (link.__claudeWebStyleFix || !isStyleSheetLink(link)) return;
    link.__claudeWebStyleFix = true;
    var url = ownURL(link);
    if (!url) {
      // Not covered by the fix; noted in the debug log in case it's where a crash comes from.
      if (link.href) report({ seen: link.href });
      return;
    }

    var held = document.readyState !== "complete";
    if (held) hide();
    getText(url.href).then(function (css) {
      if (typeof css !== "string") throw new Error("No text came back");
      var count = (css.match(RELATIVE_COLOR) || []).length;
      var how = insert(link, fix(css, url.href));
      report({ fixed: url.href, count: count, hasCount: disableAttributeHas.count || 0, how: how });
      dispatch(link, "load");
    }).catch(function (error) {
      report({ failed: url.href, error: String((error && error.message) || error) });
      dispatch(link, "error");
    }).then(function () {
      if (held) show();
    });
  }

  function scan(node) {
    if (node.nodeType !== 1) return;
    if (node.nodeName === "LINK") {
      takeOver(node);
    } else if (node.getElementsByTagName) {
      var links = node.getElementsByTagName("link");
      for (var i = 0; i < links.length; i++) takeOver(links[i]);
    }
  }

  new MutationObserver(function (records) {
    for (var i = 0; i < records.length; i++) {
      var record = records[i];
      if (record.type === "attributes") {
        scan(record.target);
      } else {
        for (var j = 0; j < record.addedNodes.length; j++) scan(record.addedNodes[j]);
      }
    }
  }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ["rel", "href"] });

  if (document.documentElement) scan(document.documentElement);
})();
