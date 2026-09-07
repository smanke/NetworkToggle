#!/bin/bash
# Builds a distributable .dmg containing the app, with the usual
# drag-to-Applications layout.
#
# Run ./build_app.sh and ./notarize.sh first: the app inside should already
# carry a stapled notarization ticket, otherwise anyone who downloads the
# image gets a Gatekeeper block on first launch. This script then signs,
# notarizes and staples the .dmg itself, so the download is clean too.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="NetworkToggle"
APP_DIR=".build/app/${APP_NAME}.app"
VERSION=$(defaults read "$(pwd)/${APP_DIR}/Contents/Info.plist" CFBundleShortVersionString)
DMG_PATH=".build/app/NetworkToggle-${VERSION}.dmg"
# Notarization credentials are account-level, not per-app, so an existing
# profile from another project works fine. Use the first one that answers.
resolve_profile() {
  for candidate in "${NOTARY_PROFILE:-}" "NetworkToggle" "DesktopBinsWidget" "DesktopBins"; do
    [ -z "${candidate}" ] && continue
    if xcrun notarytool history --keychain-profile "${candidate}" >/dev/null 2>&1; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

PROFILE=$(resolve_profile || echo "")

if [ ! -d "${APP_DIR}" ]; then
  echo "No app bundle at ${APP_DIR} — run ./build_app.sh first."
  exit 1
fi

# Warn rather than fail: a DMG of an unstapled app is still useful locally.
if ! xcrun stapler validate "${APP_DIR}" >/dev/null 2>&1; then
  echo "WARNING: the app has no stapled notarization ticket."
  echo "         Run ./notarize.sh first, or downloads will be blocked by Gatekeeper."
fi

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "${SIGN_IDENTITY}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -n 1 | sed -E 's/.*"(.*)".*/\1/' || true)
fi

echo "Staging disk image contents..."
STAGING=$(mktemp -d)
trap 'rm -rf "${STAGING}"' EXIT
cp -R "${APP_DIR}" "${STAGING}/"
# The familiar drag-the-app-onto-Applications install gesture.
ln -s /Applications "${STAGING}/Applications"

echo "Creating ${DMG_PATH}..."
rm -f "${DMG_PATH}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING}" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "${DMG_PATH}" >/dev/null

if [ -n "${SIGN_IDENTITY}" ]; then
  echo "Signing the disk image with: ${SIGN_IDENTITY}"
  codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}"

  if xcrun notarytool history --keychain-profile "${PROFILE}" >/dev/null 2>&1; then
    echo "Notarizing the disk image (a few minutes)..."
    xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${PROFILE}" --wait
    xcrun stapler staple "${DMG_PATH}"
  else
    echo "No notarization profile '${PROFILE}' — skipping notarization of the image."
  fi
else
  echo "WARNING: no Developer ID identity found; the image is unsigned."
fi

echo
echo "Verifying..."
spctl -a -t open --context context:primary-signature -vv "${DMG_PATH}" 2>&1 || true
ls -lh "${DMG_PATH}" | awk '{print "Size: "$5}'
echo "Done: ${DMG_PATH}"
