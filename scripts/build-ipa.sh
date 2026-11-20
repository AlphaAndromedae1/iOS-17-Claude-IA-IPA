#!/usr/bin/env bash
# Builds an unsigned build/ClaudeWeb.ipa. Needs a Mac with Xcode and XcodeGen (brew install xcodegen).
# Sideloadly, AltStore or SideStore sign the IPA with your Apple ID when they install it.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/Release-iphoneos/ClaudeWeb.app"
IPA="$BUILD/ClaudeWeb.ipa"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen is required: brew install xcodegen" >&2
    exit 1
fi

echo ">> Generating ClaudeWeb.xcodeproj"
xcodegen generate --quiet

echo ">> Building (unsigned)"
rm -rf "$BUILD"
xcodebuild \
    -project ClaudeWeb.xcodeproj \
    -target ClaudeWeb \
    -configuration Release \
    -sdk iphoneos \
    SYMROOT="$BUILD" \
    OBJROOT="$BUILD/obj" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    -quiet \
    build

if [ ! -d "$APP" ]; then
    echo "Build finished but $APP is missing" >&2
    exit 1
fi

echo ">> Checking the app bundle"
PLIST="$APP/Info.plist"
for key in CFBundleDisplayName CFBundleIdentifier CFBundleShortVersionString CFBundleVersion MinimumOSVersion; do
    printf '   %-27s %s\n' "$key" "$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST")"
done
printf '   %-27s %s\n' "architectures" "$(lipo -archs "$APP/ClaudeWeb")"
if [ ! -f "$APP/Assets.car" ]; then
    echo "Assets.car is missing: the icon and colours were not compiled" >&2
    exit 1
fi
if ! /usr/libexec/PlistBuddy -c "Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName" "$PLIST" >/dev/null 2>&1; then
    echo "The app icon is missing from Info.plist" >&2
    exit 1
fi
if [ ! -f "$APP/style-fix.js" ]; then
    echo "style-fix.js is missing from the app: claude.ai would load unstyled" >&2
    exit 1
fi

# The Safari extension, embedded in the app.
APPEX="$APP/PlugIns/ClaudeWebSafariFix.appex"
for file in Info.plist ClaudeWebSafariFix manifest.json rules.json host.js style-fix.js background.js icon-128.png; do
    if [ ! -f "$APPEX/$file" ]; then
        echo "The Safari extension is missing $file (looked in $APPEX)" >&2
        exit 1
    fi
done
printf '   %-27s %s\n' "Safari extension" \
    "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APPEX/Info.plist"), $(lipo -archs "$APPEX/ClaudeWebSafariFix")"

echo ">> Packaging IPA"
mkdir -p "$BUILD/ipa/Payload"
cp -R "$APP" "$BUILD/ipa/Payload/"
(cd "$BUILD/ipa" && zip -qry "$IPA" Payload)
rm -rf "$BUILD/ipa"

echo ">> Done: $IPA ($(du -h "$IPA" | cut -f1))"
