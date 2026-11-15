import Foundation

/// The two small scripts the app adds to claude.ai. The app relies on iOS 17's WebKit running
/// the site as-is, and does not intercept, rewrite or re-run any of claude.ai's own JavaScript
/// (that is what ran other wrappers out of memory). Both scripts only read, and what they report
/// goes to the app on the phone, nowhere else.
enum PageScripts {

    static let pageColorsMessage = "pageColors"
    static let networkMessage = "network"
    static let styleSheetMessage = "styleSheet"
    static let pageErrorMessage = "pageError"

    /// Reports JavaScript errors, files that failed to load and Content Security Policy refusals to
    /// Settings > Debug Log. Listens only; it doesn't change how errors are handled. At most 100
    /// reports per page, to keep a noisy page from flooding the log.
    static let errorReporter = #"""
    (function () {
      if (window.top !== window || window.__claudeWebErrors) return;
      window.__claudeWebErrors = true;

      var handlers = window.webkit && window.webkit.messageHandlers;
      var handler = handlers && handlers.pageError;
      if (!handler) return;

      var sent = 0;
      function send(kind, message, details, url) {
        if (sent >= 100) return;
        sent += 1;
        try {
          handler.postMessage({
            kind: kind,
            message: String(message).slice(0, 500),
            details: String(details || "").slice(0, 6000),
            url: url || "",
            page: location.host + location.pathname
          });
        } catch (e) {}
      }

      function short(url) {
        return String(url || "").split("#")[0].split("?")[0];
      }

      window.addEventListener("error", function (event) {
        var target = event.target;
        if (target && target !== window && target.nodeType === 1) {
          // A script, style sheet or image that failed to load.
          var url = target.src || target.href || "";
          if (url) send("resource", "Couldn't load " + target.nodeName.toLowerCase() + " " + short(url), "", url);
          return;
        }
        var where = event.filename ? short(event.filename) + ":" + event.lineno + ":" + event.colno : "";
        var stack = event.error && event.error.stack ? String(event.error.stack) : "";
        send("exception", event.message || "Script error", [where, stack].filter(Boolean).join("\n"));
      }, true);

      window.addEventListener("unhandledrejection", function (event) {
        var reason = event.reason;
        var message = reason && reason.message ? reason.message : String(reason);
        send("rejection", "Unhandled promise rejection: " + message, reason && reason.stack ? String(reason.stack) : "");
      });

      document.addEventListener("securitypolicyviolation", function (event) {
        send("csp", "Content Security Policy blocked " + (event.violatedDirective || "something"),
             "Blocked: " + short(event.blockedURI) + (event.sourceFile ? "\nSource: " + short(event.sourceFile) : ""));
      });
    })();
    """#

    /// Works around a WebKit crash on iOS 17.3. claude.ai's style sheets use CSS relative colour
    /// syntax, such as `rgb(from red r g b)` in an `@supports` test, which recent Tailwind CSS
    /// emits. The WebKit in iOS 17.3 crashes while parsing that (in `RenderThemeIOS::systemColor`),
    /// taking the page down every time it loads; Safari crashes the same way.
    ///
    /// Before WebKit parses one of claude.ai's own style sheets, this script takes the `<link>`
    /// over: it downloads the file, and if it contains relative colours, renames each one to an
    /// unknown function, which WebKit simply treats as unsupported, then adds the corrected CSS to
    /// the page in the link's place. Sheets without relative colours are handed straight back.
    static let styleFix = #"""
    (function () {
      if (window.top !== window || window.__claudeWebStyleFix) return;
      window.__claudeWebStyleFix = true;

      var OWN_HOST = /(^|\.)(claude\.ai|claude\.com|anthropic\.com)$/i;
      var HAS_RELATIVE_COLOR = /\b(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(\s*from\s/i;
      var RELATIVE_COLOR = /\b(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(\s*from\s/gi;
      var handlers = window.webkit && window.webkit.messageHandlers;
      var native = handlers && handlers.styleSheet;

      function isStyleSheetLink(node) {
        return node.nodeName === "LINK" && /(^|\s)stylesheet(\s|$)/i.test(node.getAttribute("rel") || "");
      }

      // Keep the page hidden while its first style sheets are swapped, instead of flashing it unstyled.
      var waiting = 0, safety = null;
      function hide() {
        waiting += 1;
        if (waiting === 1) {
          document.documentElement.style.setProperty("visibility", "hidden", "important");
          safety = setTimeout(function () { waiting = 1; show(); }, 5000);
        }
      }
      function show() {
        waiting = Math.max(0, waiting - 1);
        if (waiting === 0) {
          clearTimeout(safety);
          document.documentElement.style.removeProperty("visibility");
        }
      }

      function getText(href) {
        return fetch(href, { credentials: "same-origin", cache: "force-cache" })
          .then(function (response) {
            if (!response.ok) throw new Error("HTTP " + response.status);
            return response.text();
          })
          .catch(function (error) {
            // The page isn't allowed to read it (no CORS headers): the app fetches it instead.
            if (!native) throw error;
            return native.postMessage({ url: href, userAgent: navigator.userAgent });
          });
      }

      function absolute(path, base) {
        if (/^([a-z][a-z0-9+.-]*:|\/\/|#)/i.test(path)) return path;
        try { return new URL(path, base).href; } catch (e) { return path; }
      }

      function fix(css, base) {
        css = css.replace(RELATIVE_COLOR, function (match, name) {
          return "-claude-web-unsupported-" + name + "(from ";
        });
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
        if (style.sheet) return;
        // The page's Content Security Policy refused the <style>; constructed sheets aren't subject to it.
        style.remove();
        try {
          var sheet = new CSSStyleSheet(media ? { media: media } : undefined);
          sheet.replaceSync(css);
          document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
        } catch (e) {}
      }

      function takeOver(link) {
        if (link.__claudeWebStyleFix || !isStyleSheetLink(link)) return;
        var url;
        try { url = new URL(link.href, document.baseURI); } catch (e) { return; }
        if (url.protocol !== "https:" || !OWN_HOST.test(url.hostname)) return;
        link.__claudeWebStyleFix = true;

        // WebKit parses a sheet only once it has finished downloading, which is always after this
        // runs. Changing rel now drops it before that happens.
        var rel = link.getAttribute("rel");
        link.setAttribute("rel", "x-claude-web-pending");
        var held = document.readyState !== "complete";
        if (held) hide();

        getText(url.href).then(function (css) {
          if (typeof css !== "string") throw new Error("No text");
          if (!HAS_RELATIVE_COLOR.test(css)) {
            link.setAttribute("rel", rel);  // nothing to fix: let WebKit load it as usual
            return;
          }
          var count = (css.match(RELATIVE_COLOR) || []).length;
          insert(link, fix(css, url.href));
          try { native && native.postMessage({ fixed: url.href, count: count }); } catch (e) {}
          // Whoever waits on this link (a lazily loaded part of the app, say) can carry on.
          link.dispatchEvent(new Event("load"));
        }).catch(function (error) {
          link.setAttribute("rel", rel);
          try {
            native && native.postMessage({ failed: url.href, error: String(error && error.message || error) });
          } catch (e) {}
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
    """#

    /// Tells the Privacy Report which servers the page loads things from: host names and counts
    /// only, never full addresses or content. It reads the browser's own Resource Timing records,
    /// so it doesn't wrap or slow down any of the page's requests. Blocked requests aren't in those
    /// records; the app learns about them from WebKit directly.
    static let networkObserver = #"""
    (function () {
      if (window.top !== window || window.__claudeWebNetwork) return;
      window.__claudeWebNetwork = true;

      var handlers = window.webkit && window.webkit.messageHandlers;
      var handler = handlers && handlers.network;
      if (!handler || typeof PerformanceObserver !== "function") return;

      var pending = {};
      var timer = null;

      function flush() {
        timer = null;
        var batch = {};
        for (var host in pending) {
          batch[host] = { n: pending[host].n, t: Object.keys(pending[host].t) };
        }
        pending = {};
        try { handler.postMessage(batch); } catch (e) {}
      }

      function note(entries) {
        var added = false;
        for (var i = 0; i < entries.length; i++) {
          var host = "";
          try { host = new URL(entries[i].name).hostname; } catch (e) {}
          if (!host) continue;
          var item = pending[host] || (pending[host] = { n: 0, t: {} });
          item.n += 1;
          if (entries[i].initiatorType) item.t[entries[i].initiatorType] = true;
          added = true;
        }
        // One message a second at most, however busy the page is.
        if (added && timer === null) timer = setTimeout(flush, 1000);
      }

      try {
        new PerformanceObserver(function (list) { note(list.getEntries()); })
          .observe({ type: "resource", buffered: true });
      } catch (e) {}
    })();
    """#

    /// Reports the colour painted at the top and bottom edges of the page, so the native
    /// strips behind the status bar and the home indicator can match it.
    static let pageColors = #"""
    (function () {
      if (window.top !== window || window.__claudeWebPageColors) return;
      window.__claudeWebPageColors = true;

      var handlers = window.webkit && window.webkit.messageHandlers;
      var handler = handlers && handlers.pageColors;
      if (!handler) return;

      var canvas = document.createElement("canvas");
      canvas.width = canvas.height = 1;
      var ctx = canvas.getContext("2d", { willReadFrequently: true });
      if (!ctx) return;

      // Any CSS colour (rgb, hsl, oklch, ...) to [r, g, b]; null unless fully opaque.
      function toRGB(css) {
        if (!css || css === "transparent" || css === "rgba(0, 0, 0, 0)") return null;
        ctx.clearRect(0, 0, 1, 1);
        ctx.fillStyle = "rgba(0, 0, 0, 0)";
        ctx.fillStyle = css;
        ctx.fillRect(0, 0, 1, 1);
        var d = ctx.getImageData(0, 0, 1, 1).data;
        return d[3] > 250 ? [d[0], d[1], d[2]] : null;
      }

      // Background of what is painted at (x, y): the nearest opaque ancestor.
      function colorAt(x, y) {
        for (var el = document.elementFromPoint(x, y); el && el.nodeType === 1; el = el.parentElement) {
          var c = toRGB(getComputedStyle(el).backgroundColor);
          if (c) return c;
        }
        return null;
      }

      var last = "";
      var timer = null;

      function report() {
        timer = null;
        if (document.visibilityState === "hidden" || !document.body) return;
        var h = window.innerHeight;
        if (!window.innerWidth || !h) return;
        var page = toRGB(getComputedStyle(document.body).backgroundColor) ||
                   toRGB(getComputedStyle(document.documentElement).backgroundColor);
        var t = colorAt(1, 1), b = colorAt(1, h - 2);
        var top = t || page || b, bottom = b || page || t;
        if (!top || !bottom) return;
        var key = top.join(",") + "|" + bottom.join(",");
        if (key === last) return;
        last = key;
        handler.postMessage({ top: top, bottom: bottom });
      }

      function schedule() {
        if (timer === null) timer = setTimeout(report, 200);
      }

      var watch = { attributes: true, attributeFilter: ["class", "style", "data-theme", "data-mode"] };
      new MutationObserver(schedule).observe(document.documentElement, watch);
      if (document.body) new MutationObserver(schedule).observe(document.body, watch);
      if (window.matchMedia) {
        var dark = window.matchMedia("(prefers-color-scheme: dark)");
        if (dark.addEventListener) dark.addEventListener("change", schedule);
      }
      window.addEventListener("resize", schedule);
      window.addEventListener("pageshow", schedule);
      window.addEventListener("popstate", schedule);
      document.addEventListener("visibilitychange", schedule);
      // Moving around the app (opening a chat, the sidebar, settings) follows a tap and doesn't
      // reload the document, so look again shortly after each tap rather than polling on a timer.
      document.addEventListener("click", function () { setTimeout(schedule, 400); },
                                { capture: true, passive: true });
      // The app paints in stages after the document itself has loaded.
      [0, 600, 1500, 4000].forEach(function (ms) { setTimeout(schedule, ms); });
    })();
    """#
}
