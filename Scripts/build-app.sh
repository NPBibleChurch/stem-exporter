#!/bin/bash
# Assemble StemExporter.app from the SwiftPM build products.
#
# SwiftPM builds a bare executable; a SwiftUI app needs a bundle around it to get
# a menu bar, a Dock icon and TCC identity. Distribution replaces the ad-hoc
# signature here with a Developer ID one, then notarises (see README).
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/StemExporter.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/StemExporter"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StemExporter"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
ICON="$ROOT/Sources/StemExporter/Resources/AppIcon.icns"
[ -f "$ICON" ] && cp "$ICON" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad hoc)…"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "  (ad-hoc signing unavailable; the app will still run locally)"

echo "✓ $APP"
