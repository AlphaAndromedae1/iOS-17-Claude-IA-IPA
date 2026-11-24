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
        // A harmless notice browsers raise when a layout takes more than one frame to settle; not an error.
        if (/^ResizeObserver loop/i.test(event.message || "")) return;
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

    /// The iOS 17.3 style fix: `Shared/style-fix.js`, preceded
    /// by `styleFixHost`, which connects it to the app. Nil if the file is missing from the app.
    static let styleFix: String? = {
        guard let url = Bundle.main.url(forResource: "style-fix", withExtension: "js"),
              let core = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return styleFixHost + "\n" + core
    }()

    /// Gives `style-fix.js` the app's side: downloading a style sheet the page can't read (see
    /// `StyleSheetFetcher`), and the progress reports that go to the debug log.
    static let styleFixHost = #"""
    (function () {
      var handlers = window.webkit && window.webkit.messageHandlers;
      var native = handlers && handlers.styleSheet;
      window.__claudeStyleFixHost = {
        fetchText: function (url) {
          if (!native) return Promise.reject(new Error("The app isn't listening"));
          return native.postMessage({ url: url, userAgent: navigator.userAgent });
        },
        report: function (message) {
          if (native) native.postMessage(message);
        }
      };
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
