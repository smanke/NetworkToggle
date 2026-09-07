#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# ConnectorShape is compiled in rather than duplicated, so the app icon and the menu
# bar glyph are always the same drawing.
BIN=$(mktemp -d)/generate_icon
swiftc -O -parse-as-library Tools/generate_icon.swift Sources/NetworkToggle/ConnectorShape.swift -o "$BIN"
"$BIN"

SET="Resources/AppIcon.iconset"
rm -rf "$SET"; mkdir -p "$SET"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" \
            "512 icon_512x512" "1024 icon_512x512@2x"; do
  px="${spec%% *}"; name="${spec#* }"
  sips -z "$px" "$px" Resources/AppIcon.png --out "$SET/$name.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$SET"
echo "Wrote Resources/AppIcon.icns"
