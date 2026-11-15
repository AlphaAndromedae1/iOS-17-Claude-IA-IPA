import Foundation

/// The two small scripts the app adds to claude.ai. The app relies on iOS 17's WebKit running
/// the site as-is, and does not intercept, rewrite or re-run any of claude.ai's own JavaScript
/// (that is what ran other wrappers out of memory). Both scripts only read, and what they report
/// goes to the app on the phone, nowhere else.
enum PageScripts {

    static let pageColorsMessage = "pageColors"
    static let networkMessage = "network"

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
