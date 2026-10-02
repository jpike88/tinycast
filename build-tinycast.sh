#!/bin/bash
# Build a signed Release Tinycast.app and install it into /Applications.
# Kills any running Tinycast first, since replacing a running bundle can
# leave LaunchServices serving parts of two builds.
# Usage: ~/build-tinycast.sh [version]
set -euo pipefail

IDENTITY="Tinycast Self-Signed"

if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
    echo "FAIL: '$IDENTITY' code-signing identity not found - create it once (docs/signing.md section 1 in the repo)" >&2
    exit 1
fi

echo "- Building signed Tinycast.app (Release)..."
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Release \
    -derivedDataPath build/DerivedData \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    ${1:+MARKETING_VERSION="$1"} \
    build

APP="build/DerivedData/Build/Products/Release/Tinycast.app"
codesign --verify --deep --strict "$APP"

echo "- Stopping any running Tinycast..."
# Quit gracefully first so state persists, then force-kill any stragglers.
# Only the installed bundle's path is targeted, so a more recent Tinycast Dev
# build running alongside is left alone.
if pgrep -f "/Applications/Tinycast.app/Contents/MacOS/Tinycast" >/dev/null; then
    osascript -e 'tell application id "com.tinycast.app" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        pgrep -f "/Applications/Tinycast.app/Contents/MacOS/Tinycast" >/dev/null || break
        sleep 1
    done
    pkill -f "/Applications/Tinycast.app/Contents/MacOS/Tinycast" 2>/dev/null || true
    sleep 1
    echo "  stopped."
else
    echo "  not running."
fi

echo "- Installing to /Applications..."
rm -rf /Applications/Tinycast.app
cp -R "$APP" /Applications/
# A locally built app carries no quarantine; clear it anyway if some tool added it.
xattr -dr com.apple.quarantine /Applications/Tinycast.app 2>/dev/null || true

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Tinycast.app
codesign --verify --strict /Applications/Tinycast.app

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Tinycast.app/Contents/Info.plist)"
echo "OK: Installed Tinycast $VERSION to /Applications/Tinycast.app"
