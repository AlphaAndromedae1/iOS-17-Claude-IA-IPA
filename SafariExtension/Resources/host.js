// Connects style-fix.js to the Safari extension (the app has its own version of this in
// PageScripts.styleFixHost). Runs first, in the same content script world as style-fix.js.
//
// rules.json stops Safari from loading style sheets from Claude's own servers; style-fix.js then
// loads each one itself. If the page isn't allowed to read a sheet (no CORS headers), the
// extension's background script fetches it instead.
window.__claudeStyleFixHost = {
  fetchText: function (url) {
    return browser.runtime.sendMessage({ type: "fetchStyleSheet", url: url }).then(function (reply) {
      if (reply && typeof reply.text === "string") return reply.text;
      throw new Error((reply && reply.error) || "The extension couldn't load it");
    });
  },
  report: function (message) {
    // There's no debug log in Safari; these show in Web Inspector's console.
    if (message.failed) {
      console.warn("[Claude iOS 17 Fix] Couldn't load", message.failed, message.error);
    } else if (message.fixed) {
      console.info("[Claude iOS 17 Fix] Loaded", message.fixed,
        "relative colours:", message.count, ":has() disabled:", message.hasCount);
    }
  }
};
