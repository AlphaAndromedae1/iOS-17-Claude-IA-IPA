// The iOS 17.3 style fix, loaded into claude.ai by the Claude Web app (see PageScripts.styleFix).
//
// WebKit in iOS 17.3 crashes on two things in claude.ai's CSS:
//  1. Relative colour syntax, such as rgb(from red r g b) in an @supports test
//     (crash in RenderThemeIOS::systemColor while parsing the style sheet).
//  2. :has() selectors, which WebKit re-checks whenever the page changes, and sometimes crashes
//     doing so (in HTMLDocument::isCaseSensitiveAttribute, reading a selector that looks damaged).
//     Every :has() is disabled, so there is nothing left to re-check.
//
// The app's content rule list (StyleFixRules) stops WebKit from loading style sheets from Claude's
// own servers, so it never parses the originals. This script loads each of those sheets itself,
// renames every relative colour and every :has() to something WebKit treats as unsupported (as a
// browser without them would), and adds the result to the page right where the <link> is. The link's blocked
// "error" is kept from the page, which gets "load" instead once the copy is in place. Style sheets
// the page preloads (<link rel="preload" as="style">) are blocked too, and answered the same way.
//
// CSS that doesn't come from those files is handled too. A <style> a script adds is rewritten just
// before it goes in; one already in the page (including inside shadow roots) has its parsed :has()
// rules swapped for inert ones as soon as it appears, since the :has() crash only happens later,
// when the page changes. Rules added by the page's scripts (insertRule, replace, replaceSync) are
// rewritten before WebKit reads them.
//
// Before this runs, the app sets window.__claudeStyleFixHost (PageScripts.styleFixHost):
//   fetchText(url) -> Promise<string>   downloads a sheet the page itself isn't allowed to read
//   report(message)                     receives { fixed, count, hasCount, how } | { failed, error } | { seen }
//                                       | { runtime, styles, rules, count, hasCount }

(function () {
  if (window.top !== window || window.__claudeWebStyleFix) return;
  window.__claudeWebStyleFix = true;

  // Keep in step with StyleFixRules.hosts in the app.
  var OWN_HOST = /(^|\.)(claude\.ai|claude\.com|anthropic\.com)$/i;
  // Not after a letter, digit or "-", so text that has already been renamed isn't renamed again.
  var RELATIVE_COLOR = /(^|[^\w-])(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(\s*from\s/gi;
  var HAS = /:has\(/gi;
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

  // Renames relative colours and :has() to names WebKit doesn't know, so it skips them instead of
  // crashing. Safe to run on text that has already been through it.
  function rewrite(css) {
    var count = 0, hasCount = 0;
    css = css.replace(RELATIVE_COLOR, function (match, before, name) {
      count++;
      return before + "-claude-web-unsupported-" + name + "(from ";
    });
    css = css.replace(HAS, function () {
      hasCount++;
      return ":-claude-web-unsupported-has(";
    });
    return { css: css, count: count, hasCount: hasCount };
  }

  function needsRewrite(css) {
    RELATIVE_COLOR.lastIndex = 0;
    HAS.lastIndex = 0;
    var needed = RELATIVE_COLOR.test(css) || HAS.test(css);
    RELATIVE_COLOR.lastIndex = 0;
    HAS.lastIndex = 0;
    return needed;
  }

  function fix(css, base) {
    var result = rewrite(css);
    // Paths inside the file were relative to it; it now lives in the page, so make them absolute.
    result.css = result.css.replace(/url\(\s*(['"]?)([^'")\s]+)\1\s*\)/gi, function (match, quote, path) {
      return "url(" + quote + absolute(path, base) + quote + ")";
    }).replace(/@import\s+(['"])([^'"]+)\1/gi, function (match, quote, path) {
      return "@import " + quote + absolute(path, base) + quote;
    });
    return result;
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
      var result = fix(css, url.href);
      var how = insert(link, result.css);
      report({ fixed: url.href, count: result.count, hasCount: result.hasCount, how: how });
      dispatch(link, "load");
    }).catch(function (error) {
      report({ failed: url.href, error: String((error && error.message) || error) });
      dispatch(link, "error");
    }).then(function () {
      if (held) show();
    });
  }

  // CSS that the page puts in <style> elements or adds from its scripts. Counted and reported
  // every couple of seconds rather than one message per rule.
  var runtime = null;
  function noteRuntime(kind, result) {
    if (!runtime) {
      runtime = { runtime: true, styles: 0, rules: 0, count: 0, hasCount: 0 };
      setTimeout(function () {
        var message = runtime;
        runtime = null;
        report(message);
      }, 2000);
    }
    runtime[kind] += 1;
    runtime.count += result.count;
    runtime.hasCount += result.hasCount;
  }

  // A <style> already in the page: WebKit has parsed it, so swap each :has() rule in the parsed
  // sheet for an inert one. Editing the parsed rules (rather than the text) keeps rules the page's
  // scripts added with insertRule, and their numbering.
  function fixStyleElement(style) {
    if (style.hasAttribute("data-claude-web-fixed")) return;  // one of ours, already fixed
    var sheet = style.sheet;
    if (!sheet) return;
    var result = { count: 0, hasCount: 0 };
    disableHasRules(sheet, result);
    if (result.hasCount) noteRuntime("styles", result);
  }

  function disableHasRules(group, result) {
    var rules;
    try { rules = group.cssRules; } catch (e) { return; }
    if (!rules) return;
    for (var i = 0; i < rules.length; i++) {
      var rule = rules[i];
      HAS.lastIndex = 0;
      if (typeof rule.selectorText === "string" && HAS.test(rule.selectorText)) {
        try {
          group.deleteRule(i);
          group.insertRule("@media not all {}", i);
          result.hasCount++;
        } catch (e) {}
      } else if (rule.cssRules) {
        disableHasRules(rule, result);  // inside @media, @supports, @layer or a nested rule
      }
    }
    HAS.lastIndex = 0;
  }

  // A <style> a script is about to add: rewrite its text first, so WebKit never parses the original.
  function prepareStyle(node) {
    if (!node || node.nodeName !== "STYLE" || node.isConnected) return;
    var css = node.textContent || "";
    if (!css || !needsRewrite(css)) return;
    var result = rewrite(css);
    node.textContent = result.css;
    noteRuntime("styles", result);
  }

  function wrapInsertion(name) {
    var original = window.Node && Node.prototype[name];
    if (typeof original !== "function") return;
    Node.prototype[name] = function (node) {
      prepareStyle(node);
      return original.apply(this, arguments);
    };
  }
  wrapInsertion("appendChild");
  wrapInsertion("insertBefore");

  // insertRule throws if the rule doesn't parse, which a renamed :has() makes happen. Put an inert
  // rule in its place instead, so the page's code carries on and its rule numbering stays right.
  function wrapInsertRule(prototype) {
    if (!prototype || typeof prototype.insertRule !== "function") return;
    var original = prototype.insertRule;
    prototype.insertRule = function (rule) {
      if (typeof rule !== "string" || !needsRewrite(rule)) return original.apply(this, arguments);
      var result = rewrite(rule);
      noteRuntime("rules", result);
      var args = Array.prototype.slice.call(arguments);
      args[0] = result.css;
      try {
        return original.apply(this, args);
      } catch (error) {
        args[0] = "@media not all {}";
        return original.apply(this, args);
      }
    };
  }

  // Whole style sheets given to replace()/replaceSync(): rules that no longer parse are just skipped.
  function wrapReplace(prototype, name) {
    if (!prototype || typeof prototype[name] !== "function") return;
    var original = prototype[name];
    prototype[name] = function (text) {
      if (typeof text !== "string" || !needsRewrite(text)) return original.apply(this, arguments);
      var result = rewrite(text);
      noteRuntime("rules", result);
      var args = Array.prototype.slice.call(arguments);
      args[0] = result.css;
      return original.apply(this, args);
    };
  }

  var sheetPrototype = window.CSSStyleSheet && CSSStyleSheet.prototype;
  wrapInsertRule(sheetPrototype);
  wrapInsertRule(window.CSSGroupingRule && CSSGroupingRule.prototype);
  wrapReplace(sheetPrototype, "replace");
  wrapReplace(sheetPrototype, "replaceSync");

  function scan(node) {
    if (node.nodeType !== 1) return;
    if (node.nodeName === "LINK") {
      takeOver(node);
    } else if (node.nodeName === "STYLE") {
      fixStyleElement(node);
    } else if (node.getElementsByTagName) {
      var links = node.getElementsByTagName("link");
      for (var i = 0; i < links.length; i++) takeOver(links[i]);
      var styles = node.getElementsByTagName("style");
      for (var j = 0; j < styles.length; j++) fixStyleElement(styles[j]);
    }
  }

  var observing = { childList: true, subtree: true, attributes: true, attributeFilter: ["rel", "href"] };
  var observer = new MutationObserver(function (records) {
    for (var i = 0; i < records.length; i++) {
      var record = records[i];
      if (record.type === "attributes") {
        scan(record.target);
      } else if (record.target.nodeName === "STYLE") {
        fixStyleElement(record.target);  // text added to or replaced in a <style>
      } else {
        for (var j = 0; j < record.addedNodes.length; j++) scan(record.addedNodes[j]);
      }
    }
  });
  observer.observe(document, observing);

  // Shadow roots (web components) have their own <style> and <link> elements.
  var attachShadow = window.Element && Element.prototype.attachShadow;
  if (attachShadow) {
    Element.prototype.attachShadow = function () {
      var root = attachShadow.apply(this, arguments);
      try { observer.observe(root, observing); } catch (e) {}
      return root;
    };
  }

  if (document.documentElement) scan(document.documentElement);
})();
