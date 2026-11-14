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

echo ">> Packaging IPA"
mkdir -p "$BUILD/ipa/Payload"
cp -R "$APP" "$BUILD/ipa/Payload/"
(cd "$BUILD/ipa" && zip -qry "$IPA" Payload)
rm -rf "$BUILD/ipa"

echo ">> Done: $IPA ($(du -h "$IPA" | cut -f1))"
