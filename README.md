# Claude Web for iOS 16.4 – 17

A small native iPhone/iPad app that runs [claude.ai](https://claude.ai) full screen, for devices
that can't install the current official Claude app (which now needs iOS 18).

It is an unofficial personal project, not made or endorsed by Anthropic.

## Why another wrapper?

| | Official app 1.251215.4 | [claude-legacy-ios](https://github.com/mgefimov/claude-legacy-ios) | This app |
|---|---|---|---|
| Installs on iOS 17 | Yes | Yes | Yes |
| Can sign in | **No**: the server rejects old app versions ("this version of the app is too old") | Yes | Yes |
| Memory use | n/a | **High**: every claude.ai script is parsed and rewritten at runtime, which can make iOS stop the page ("The web process stopped — the device may have run out of memory") | Same as Safari |

claude-legacy-ios targets iOS 13–15, where Safari can't run claude.ai's JavaScript. To fix that it
downloads every script, parses it with a JavaScript parser (Acorn), rewrites it, sends the code
through the native bridge and evaluates it again. That is needed on iOS 15. On iOS 17 it is
pure overhead and pushes the web process past its memory limit.

The WebKit in **iOS 16.4 and later runs claude.ai without changes**, with one exception, covered
below. This app loads the site as is. It doesn't transpile or re-run claude.ai's JavaScript. What it
adds is small: a fix for an iOS 17.3 crash, read-only scripts for the status-bar colour, the Privacy
Report and the debug log, and tracker blocking.

### The iOS 17.3 crash fix

Recently, claude.ai started crashing on iOS 17.3, in Safari too, with
"The web process stopped" / "Claude keeps stopping". The crash report showed it happening inside
WebKit (`WebCore::RenderThemeIOS::systemColor`) while reading one of claude.ai's style sheets. The
trigger is CSS **relative colour syntax** such as `rgb(from red r g b)` in an `@supports` test,
the kind of rule recent versions of Tailwind CSS emit.

The app doesn't let WebKit load style sheets from Claude's own servers (a content rule list, the
mechanism Safari content blockers use), so WebKit never reads the originals. Instead, the app loads
each of those files itself and renames every relative colour to an unknown function. WebKit ignores
unknown functions instead of crashing, the same way it treats any CSS feature it doesn't support.
The corrected CSS is then added to the page right where the original `<link>` was. Files without
relative colours are added unchanged. Settings → Debug Log lists every file that went through the
fix, and whether anything was changed.

A second iOS 17.3 crash comes from CSS `:has()` selectors that test an attribute, such as
`:has([data-state=open])`, which Tailwind generates for its `has-[…]` styles. When the page changes,
WebKit re-checks those selectors and crashes (in `HTMLDocument::isCaseSensitiveAttribute`). The fix
disables just those selectors, so WebKit skips them as a browser without `:has()` would. Other
`:has()` selectors still work. A few small visual touches that depend on them may be missing.

(Version 1.3.0 tried to swap the files from a script while WebKit was still downloading them. WebKit
reads a style sheet as soon as its download finishes, and that happened first, so it still crashed.
Blocking the download avoids that race.)

## Features

- Stays signed in (persistent cookies and storage, like Safari).
- Reopens the chat or project you were last in.
- Works around the iOS 17.3 WebKit crash on claude.ai's current style sheets (see above).
- Tries to recover on its own when iOS closes the page. If that keeps happening, it shows why
  (crash or memory limit) instead of looping.
- Sign-in pop-ups (Google, Apple) open in a sheet and return to the app when finished.
- Links to other sites open in an in-app Safari sheet; `mailto:`, `tel:` and similar links open the right app.
- File, photo and camera uploads; microphone for dictation and voice mode.
- Downloads (artifacts, exported files) open the share sheet, so you can use Save to Files and similar.
- Swipe from the edge to go back and forward.
- Blocks known tracking, analytics and advertising services, and includes a Privacy Report (see below).
- Dismisses claude.ai's "get the Claude app" prompts, and keeps links that would open the Claude app
  inside this app instead.
- **Shake the phone** to open the menu: Reload, New Chat, Open Copied Link, Open in Safari, and
  **Settings & Debug Log**.

## Fixing Safari too

The app includes a **Safari Web Extension** ("Claude iOS 17 Fix") with the same iOS 17.3 fix, so
claude.ai stops crashing in Safari as well. It uses Apple's standard extension system, so it works
without a jailbreak. After installing the app:

1. Open the Settings app, then **Safari → Extensions → Claude iOS 17 Fix**, and switch it on.
2. Set **claude.ai** and **anthropic.com** to *Allow*, or set *All Websites* to *Allow*. The extension
   only asks for access to Claude's own sites (claude.ai, claude.com, anthropic.com), so that's all it
   can reach.
3. Reload claude.ai in Safari.

It works like the app's fix. A blocking rule (`SafariExtension/Resources/rules.json`) stops Safari
from loading style sheets from Claude's servers, and a content script loads, corrects and inserts
them. If the extension is switched on but not allowed on those sites, the blocking rule still
applies while the script doesn't run, so claude.ai looks unstyled in Safari. Allow the sites, or
switch the extension off. Corrections show in Web Inspector's console as `[Claude iOS 17 Fix]`.

Both the app and the extension run the same file, `Shared/style-fix.js`. Each connects it to its own
download fallback and reporting: `PageScripts.styleFixHost` in the app, and
`SafariExtension/Resources/host.js` in the extension.

## Settings & Debug Log

Shake the phone and choose **Settings & Debug Log**, or tap the button on the error screen.

- **Claude Web:** app version, device, iOS version, and whether the add-ons are on.
- **Blocking:** switches for *Block Trackers*, *Hide "Get the App" Prompts* and the *iOS 17 Style Fix*,
  plus *Privacy Report & Block List* for editing the blocked addresses. Each switch reloads the page.
- **Debug Log:** what happened, newest first, with a *Problems* filter. Tap an entry for its full
  details; *Share* sends the whole log as text. It records:
  - page loads, load errors (error domain, code and address), HTTP errors, Cloudflare checks
  - the web page crashing or hitting the memory limit, with WebKit's reason code
  - JavaScript errors and unhandled promise rejections from claude.ai, with stack traces
  - files that failed to load, and requests refused by the page's Content Security Policy
  - style sheets the iOS 17 fix corrected, or couldn't
  - downloads, pop-up windows and low-memory warnings

  The log stays on the phone, in the app's Caches folder, and keeps the last 500 entries, so it survives
  closing the app. Page addresses are logged without their query strings. Nothing from your
  conversations is recorded.
- **Copy Diagnostics:** a short summary, plus the latest problems from the log, to paste into a chat.
- **Load a Test Page** / **Reload Without Add-ons:** see Troubleshooting below.
- **Clear Cache** (keeps you signed in) and **Sign Out and Reset**.

The iOS Settings app can only show fixed preferences, not a live log, so these settings live inside
the app.

### "Get the app" prompts

claude.ai's code isn't something this app can see ahead of time, so prompts are recognised by what
they say and where they sit, not by class names. To be dismissed, an element must:

- float over the page (a dialog, or a fixed or sticky banner or sheet)
- mention the app ("Get the app", "Claude app", "App Store", "Claude for iOS"), or link to the App Store
  or a `claude://` address
- be small: short text, at most six buttons or links, and no message box, navigation or conversation

Those rules keep it away from chats and the sidebar. It taps the prompt's own *Not now* or close
button where there is one, so claude.ai remembers the choice. Otherwise it presses Escape on a dialog,
and only as a last resort hides the prompt. Every dismissal is listed in the Debug Log under
*App prompt*. If one still shows, or the wrong thing disappears, turn the switch off and send a
screenshot.

## Privacy

The app has no analytics, ads or third-party code of its own, and the only addresses built into it
are claude.ai's. What it keeps stays on the phone: login cookies and site data, the address of
your last chat, and downloads until you've saved them.

### Tracker blocking

Requests to known tracking services are stopped inside WebKit, the same way Safari content blockers
work, so they never leave the phone. The default list, in `ClaudeWeb/TrackerBlocker.swift`, only
contains services whose sole job is measuring, recording or advertising:

- **Product analytics:** Segment, Amplitude, Mixpanel, Heap, Google Analytics and Tag Manager,
  Cloudflare Web Analytics, Microsoft Clarity, HubSpot analytics
- **Session recording:** Hotjar, FullStory, LogRocket, Mouseflow, Smartlook
- **Error reporting:** Sentry, Datadog browser monitoring, New Relic
- **Advertising and conversion pixels:** Google Ads and DoubleClick, Meta, X/Twitter, LinkedIn,
  Reddit, TikTok, Bing, Pinterest, Snapchat, Criteo, Xandr

None of these runs a Claude feature, so blocking them can't take one away, and a rule for a
service claude.ai doesn't use simply never matches. These are deliberately **not** blocked, because
claude.ai may rely on them:

- feature-flag services such as Statsig and LaunchDarkly
- the Intercom support chat
- Cloudflare's security check, reCAPTCHA and hCaptcha
- Stripe payments

### Privacy Report

Open **Settings & Debug Log → Privacy Report & Block List** to see:

- **Blocked This Session:** requests the block list stopped.
- **Other Companies:** every non-Anthropic server the page contacted, with request counts and types
  (script, fetch, image, …). Each has a switch to block it.
- **Anthropic:** Claude's own servers. Analytics can be sent through Anthropic's own addresses as well.
- **Needed for Claude to Work:** sign-in, Cloudflare's check, payments, artifacts and app files.
  These can't be blocked.
- **Block List:** every entry, with switches, plus *Add Address…* and *Restore Default List*.

Changes apply when you close the report, and the page reloads. If something in Claude stops working,
unblock the last address you added. **Copy** puts a plain-text summary (addresses and counts only) on
the clipboard, so you can paste it into a chat and ask what each entry is.

Limits:
- The log lives in memory only and starts empty each time the app opens.
- Requests made inside embedded frames, such as an artifact or the payment form, aren't listed one
  by one. The frames themselves are listed.
- WebSocket connections aren't listed.
- The blocked count relies on a WebKit callback that Apple doesn't document. If a future iOS drops
  it, blocking still works, but that section stays empty.

## Installing on your iPhone

TrollStore does **not** support iOS 17.3.1, so you need a sideloading tool that signs the app with
your Apple ID:

1. Get `ClaudeWeb.ipa`:
   - **Releases** page (when a version tag has been pushed), or
   - **Actions** tab → latest *Build IPA* run → *Artifacts* → `ClaudeWeb-ipa` (a zip containing the IPA).
2. Install it with one of:
   - [Sideloadly](https://sideloadly.io) (Windows/Mac): connect the iPhone, drop in the IPA, sign in with your Apple ID.
   - [AltStore](https://altstore.io) or [SideStore](https://sidestore.io).
3. On the iPhone, trust the developer: Settings → General → VPN & Device Management.
   iOS 16+ also asks you to turn on **Developer Mode**: Settings → Privacy & Security → Developer Mode.

With a free Apple ID, sideloaded apps expire after **7 days** and must be refreshed (AltStore/SideStore
can do this automatically). A paid developer account makes that one year.

## Signing in

- **Email** works in any web view. Enter your email, then:
  - type the code from the email into the app if the email has one, or
  - press and hold the sign-in link in Mail → **Copy Link**, open the app, shake, and choose **Open Copied Link**.

  Just tapping the link opens it in Safari, which signs Safari in, not this app. If the old official
  Claude app is still installed, tapping the link may open that app instead. You can delete it,
  since it can no longer sign in.
- **Google / Apple**: the app identifies itself as Mobile Safari and opens these sign-in windows in a sheet,
  so they should work. Google sometimes still refuses sign-in from apps that embed web pages. If it does,
  use email with the same address as your Google account; it signs you in to the same Claude account.

## Building it yourself

GitHub Actions builds the IPA on every push (see `.github/workflows/build-ipa.yml`). To publish a
release, either:

- on github.com: **Releases → Draft a new release**, type a new tag such as `v1.0.0`, pick the branch
  with the code as the target and click **Publish release**, or
- from a clone: push a tag.

```bash
git tag v1.0.0
```

```bash
git push origin v1.0.0
```

Either way, the workflow builds the app and attaches `ClaudeWeb.ipa` to the release a few minutes later.

On a Mac with Xcode 15 or later:

```bash
brew install xcodegen
```

```bash
./scripts/build-ipa.sh
```

The IPA is written to `build/ClaudeWeb.ipa`. To work in Xcode instead, run `xcodegen generate` and open
`ClaudeWeb.xcodeproj`. The Xcode project is generated from `project.yml` and isn't checked in.

### Project layout

| File | What it does |
|---|---|
| `ClaudeWeb/WebViewController.swift` | Main screen: web view setup, crash recovery, downloads, shake menu |
| `ClaudeWeb/PopupViewController.swift` | Windows the page opens itself (sign-in pop-ups) |
| `ClaudeWeb/LinkRouter.swift` | Which URLs stay in the app, open in Safari, or open another app |
| `ClaudeWeb/PageScripts.swift` | Scripts added to the page: style fix host, status-bar colour, server list, error reporter, app prompts |
| `ClaudeWeb/TrackerBlocker.swift` | Default block list, essential hosts, compiling the WebKit content rules |
| `ClaudeWeb/NetworkLog.swift` | In-memory record of contacted and blocked servers |
| `ClaudeWeb/NetworkReportViewController.swift` | The Privacy Report screen |
| `ClaudeWeb/SettingsViewController.swift` | The Settings screen |
| `ClaudeWeb/DebugLog.swift`, `DebugLogViewController.swift` | The debug log and its screens |
| `ClaudeWeb/StyleSheetFetcher.swift` | Native half of the iOS 17.3 style fix |
| `Shared/style-fix.js` | The iOS 17.3 style fix itself, used by the app and the Safari extension |
| `SafariExtension/` | The Safari extension: manifest, blocking rules, host and background scripts |
| `ClaudeWeb/Support.swift` | Colours, Safari user agent, JavaScript alert/confirm/prompt dialogs |
| `Supporting/Info.plist` | App name, permissions text, orientations |
| `scripts/make-icon.py` | Regenerates the app icon |

To change the home-screen name, edit `CFBundleDisplayName` in `Supporting/Info.plist`.

### Debugging

Debug builds run from Xcode can be inspected; the release IPA built by GitHub Actions can't. To inspect a
debug build, connect the iPhone to a Mac and enable Settings → Safari → Advanced → Web Inspector. Then, in
Safari on the Mac, choose Develop → *your iPhone* → claude.ai.

## Troubleshooting

If you see **"Claude keeps stopping"**, the screen shows why iOS stopped the page (a crash or the
memory limit) along with your device and iOS version. Open **Settings & Debug Log**, check the Debug
Log for the details, then try:

1. **Load a Test Page** shows a tiny page the app makes itself, with no network.
   - If it stays up, WebKit works and the problem is specific to claude.ai.
   - If it stops too, WebKit is failing in this app for any page. That usually comes from something
     installed on the phone, such as a jailbreak tweak that loads into apps or web content.
2. **Reload Without Add-ons** loads claude.ai without anything the app adds, including the iOS 17
   style fix, until the app is next opened. If Claude then works, one of the app's additions was the
   cause. If it then crashes, the style fix was doing its job.
3. **Copy Diagnostics** copies your device, iOS version, each time the page stopped (with the
   reason) and the latest problems from the debug log. There's no chat content in it.

Also worth checking: does claude.ai open in **Safari** on the same phone? If Safari fails too, the
problem is the phone, not this app. iOS also records these events under Settings → Privacy & Security →
Analytics & Improvements → Analytics Data. Entries starting with `com.apple.WebKit.WebContent` are
crashes, and `JetsamEvent` entries are memory kills.

## Limitations

- Needs iOS 16.4 or later. For iOS 13–16.3, use claude-legacy-ios.
- This is the claude.ai website, so features that only exist in the native app aren't here
  (widgets, Shortcuts actions, native share extension).
- Not tested on every device. On phones with little memory, iOS can still close a very long chat;
  the app reloads it.
