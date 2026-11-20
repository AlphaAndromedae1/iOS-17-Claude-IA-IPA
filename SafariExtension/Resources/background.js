// Downloads a style sheet for style-fix.js when the page itself isn't allowed to read it (no CORS
// headers). Only https files on Claude's own domains are fetched.
var OWN_HOST = /(^|\.)(claude\.ai|claude\.com|anthropic\.com)$/i;

browser.runtime.onMessage.addListener(function (message, sender, sendResponse) {
  if (!message || message.type !== "fetchStyleSheet") return false;

  var url;
  try {
    url = new URL(message.url);
  } catch (e) {
    sendResponse({ error: "Not a valid address" });
    return false;
  }
  if (url.protocol !== "https:" || !OWN_HOST.test(url.hostname)) {
    sendResponse({ error: "Only Claude's own style sheets can be fetched" });
    return false;
  }

  fetch(url.href, { credentials: "include" })
    .then(function (response) {
      if (!response.ok) throw new Error("HTTP " + response.status);
      return response.text();
    })
    .then(function (text) {
      sendResponse({ text: text });
    }, function (error) {
      sendResponse({ error: String((error && error.message) || error) });
    });
  return true;  // the answer comes later
});
