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

# A second IPA for TrollStore (Lite). TrollStore signs apps without an Apple developer identity,
# and Safari seems to skip extensions that have none, so "Claude iOS 17 Fix" never appears in
# Safari's settings. Here the app and extension are pre-signed with entitlements that state a
# developer identity (team ID). TrollStore keeps an app's entitlements when it installs it, and
# registers the team ID from them. Experimental: Safari may check the signing certificate instead.
TS_IPA="$BUILD/ClaudeWeb-TrollStore.ipa"
TEAM_ID="CLAUDEWEB1"
if ! command -v ldid >/dev/null 2>&1; then
    echo ">> Skipping $TS_IPA: ldid isn't installed (brew install ldid)"
    exit 0
fi

echo ">> Packaging TrollStore IPA (team ID $TEAM_ID in the entitlements)"
TS="$BUILD/trollstore"
rm -rf "$TS"
mkdir -p "$TS/Payload"
cp -R "$APP" "$TS/Payload/"
TS_APP="$TS/Payload/ClaudeWeb.app"
TS_APPEX="$TS_APP/PlugIns/ClaudeWebSafariFix.appex"

write_entitlements() {  # bundle-id, output file
    cat > "$2" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>$TEAM_ID.$1</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM_ID</string>
</dict>
</plist>
EOF
}

APP_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$TS_APP/Info.plist")
APPEX_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$TS_APPEX/Info.plist")
write_entitlements "$APP_ID" "$TS/app.entitlements"
write_entitlements "$APPEX_ID" "$TS/extension.entitlements"

# The extension first, then the app that contains it.
ldid -S"$TS/extension.entitlements" "$TS_APPEX/ClaudeWebSafariFix"
ldid -S"$TS/app.entitlements" "$TS_APP/ClaudeWeb"
for binary in "$TS_APPEX/ClaudeWebSafariFix" "$TS_APP/ClaudeWeb"; do
    if ! ldid -e "$binary" | grep -q "<string>$TEAM_ID</string>"; then
        echo "Signing $binary didn't embed the team ID" >&2
        exit 1
    fi
done
printf '   %-27s %s\n' "app entitlements" "$(ldid -e "$TS_APP/ClaudeWeb" | grep -A1 application-identifier | tail -1 | sed -E 's/ *<\/?string>//g')"
printf '   %-27s %s\n' "extension entitlements" "$(ldid -e "$TS_APPEX/ClaudeWebSafariFix" | grep -A1 application-identifier | tail -1 | sed -E 's/ *<\/?string>//g')"

(cd "$TS" && zip -qry "$TS_IPA" Payload)
rm -rf "$TS"
echo ">> Done: $TS_IPA ($(du -h "$TS_IPA" | cut -f1))"
