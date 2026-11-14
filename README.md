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

The WebKit in **iOS 16.4 and later runs claude.ai without changes**. This app loads the site as is
and adds just one tiny script (about 60 lines) that matches the status-bar colour to the page.

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
- **Shake the phone** to open the menu:
  - Reload
  - New Chat
  - Open Copied Link
  - Open in Safari
  - Clear Cache
  - Sign Out and Reset

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

GitHub Actions builds the IPA on every push (see `.github/workflows/build-ipa.yml`). To publish a release:

```bash
git tag v1.0.0
```

```bash
git push origin v1.0.0
```

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
| `ClaudeWeb/PageScripts.swift` | The single script injected into the page (status-bar colour) |
| `ClaudeWeb/Support.swift` | Colours, Safari user agent, JavaScript alert/confirm/prompt dialogs |
| `Supporting/Info.plist` | App name, permissions text, orientations |
| `scripts/make-icon.py` | Regenerates the app icon |

To change the home-screen name, edit `CFBundleDisplayName` in `Supporting/Info.plist`.

### Debugging

The web view is inspectable. Connect the iPhone to a Mac, enable Settings → Safari → Advanced → Web Inspector,
then in Safari on the Mac choose Develop → *your iPhone* → claude.ai.

## Limitations

- Needs iOS 16.4 or later. For iOS 13–16.3, use claude-legacy-ios.
- This is the claude.ai website, so features that only exist in the native app aren't here
  (widgets, Shortcuts actions, native share extension).
- Not tested on every device. On phones with little memory, iOS can still close a very long chat;
  the app reloads it.
