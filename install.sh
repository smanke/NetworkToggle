#!/bin/bash
# Installs the built app to /Applications and launches it.
#
# SMAppService refuses to register a daemon for an app running anywhere else, so this
# is not merely a convenience: NetworkToggle cannot work from the build directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/.build/app/NetworkToggle.app"
DEST="/Applications/NetworkToggle.app"

[ -d "$SRC" ] || { echo "Run ./build_app.sh first." >&2; exit 1; }

pkill -x NetworkToggle 2>/dev/null || true

if [ -d "$DEST" ]; then
  # Update in place. Replacing the directory outright would orphan the daemon
  # registration and send the user back through the approval prompt.
  rsync -a --delete "$SRC/" "$DEST/"
else
  cp -R "$SRC" "$DEST"
fi

open "$DEST"
echo "Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
