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

The WebKit in **iOS 16.4 and later runs claude.ai without changes**. This app loads the site as is.
It adds two small read-only scripts, one to match the status-bar colour to the page and one to list
contacted servers for the Privacy Report, and it blocks known trackers.

## Features

- Stays signed in (persistent cookies and storage, like Safari).
- Reopens the chat or project you were last in.
- Tries to recover on its own when iOS closes the page for memory. If that keeps happening, it shows
  a screen with Reload and Options instead of looping.
- Sign-in pop-ups (Google, Apple) open in a sheet and return to the app when finished.
- Links to other sites open in an in-app Safari sheet; `mailto:`, `tel:` and similar links open the right app.
- File, photo and camera uploads; microphone for dictation and voice mode.
- Downloads (artifacts, exported files) open the share sheet, so you can use Save to Files and similar.
- Swipe from the edge to go back and forward.
- Blocks known tracking, analytics and advertising services, and includes a Privacy Report (see below).
- **Shake the phone** to open the menu:
  - Reload
  - New Chat
  - Open Copied Link
  - Open in Safari
  - Privacy Report
  - Clear Cache
  - Sign Out and Reset

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

Shake the phone and choose **Privacy Report** to see:

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
| `ClaudeWeb/PageScripts.swift` | The two read-only scripts added to the page (status-bar colour, server list) |
| `ClaudeWeb/TrackerBlocker.swift` | Default block list, essential hosts, compiling the WebKit content rules |
| `ClaudeWeb/NetworkLog.swift` | In-memory record of contacted and blocked servers |
| `ClaudeWeb/NetworkReportViewController.swift` | The Privacy Report screen |
| `ClaudeWeb/Support.swift` | Colours, Safari user agent, JavaScript alert/confirm/prompt dialogs |
| `Supporting/Info.plist` | App name, permissions text, orientations |
| `scripts/make-icon.py` | Regenerates the app icon |

To change the home-screen name, edit `CFBundleDisplayName` in `Supporting/Info.plist`.

### Debugging

Debug builds run from Xcode can be inspected; the release IPA built by GitHub Actions can't. To inspect a
debug build, connect the iPhone to a Mac and enable Settings → Safari → Advanced → Web Inspector. Then, in
Safari on the Mac, choose Develop → *your iPhone* → claude.ai.

## Limitations

- Needs iOS 16.4 or later. For iOS 13–16.3, use claude-legacy-ios.
- This is the claude.ai website, so features that only exist in the native app aren't here
  (widgets, Shortcuts actions, native share extension).
- Not tested on every device. On phones with little memory, iOS can still close a very long chat;
  the app reloads it.
