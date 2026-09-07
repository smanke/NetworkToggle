#!/bin/bash
# Assembles NetworkToggle.app, including the privileged helper, and signs both.
#
# The signature matters beyond distribution: SMAppService will only register a daemon
# for an app whose signature satisfies the requirement baked into NetworkToggleIDs, and
# both sides of the XPC connection check the other against it. Ad-hoc signing produces
# a code-hash-based identity that changes on every build, so it cannot be used here.
set -euo pipefail

APP_NAME="NetworkToggle"
BUNDLE_ID="com.smanke.NetworkToggle"
HELPER_ID="com.smanke.NetworkToggle.Helper"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build/app"
APP="$BUILD/$APP_NAME.app"

echo "==> Building universal binaries"
swift build -c release --arch arm64 --arch x86_64

BIN_DIR="$ROOT/.build/apple/Products/Release"
[ -x "$BIN_DIR/$APP_NAME" ] || BIN_DIR="$ROOT/.build/release"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"

cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/${APP_NAME}Helper" "$APP/Contents/MacOS/${APP_NAME}Helper"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Helper-Launchd.plist" "$APP/Contents/Library/LaunchDaemons/$HELPER_ID.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "==> Resolving signing identity"
IDENTITY="${1:-}"
if [ -z "$IDENTITY" ]; then
  FOUND=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
  if [ -z "$FOUND" ]; then
    echo "No Developer ID Application identity found in the keychain." >&2
    echo "NetworkToggle cannot run ad-hoc signed: SMAppService rejects the daemon." >&2
    exit 1
  fi
  IDENTITY=$(echo "$FOUND" | sed -E 's/.*"(.*)"$/\1/')
fi
echo "    $IDENTITY"

echo "==> Signing"
# Inside out: the helper carries its own identifier so the app's requirement string
# ("identifier com.smanke.NetworkToggle.Helper and ...") actually matches it.
codesign --force --options runtime --timestamp \
  --identifier "$HELPER_ID" \
  --sign "$IDENTITY" \
  "$APP/Contents/MacOS/${APP_NAME}Helper"

codesign --force --options runtime --timestamp \
  --identifier "$BUNDLE_ID" \
  --entitlements "$ROOT/Resources/NetworkToggle.entitlements" \
  --sign "$IDENTITY" \
  "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --requirements - "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Built $APP ($VERSION)"
echo "Install with ./install.sh — the helper only registers from /Applications."
