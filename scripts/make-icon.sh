#!/bin/bash
# Regenerates resources/AppIcon.icns from resources/logo.svg, and MenuBarIcon.pdf from menubar.svg.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
rsvg-convert -w 1024 -h 1024 resources/logo.svg -o "$WORK/logo.png"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/logo.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$WORK/logo.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o resources/AppIcon.icns
rm -rf "$WORK"
rsvg-convert -f pdf resources/menubar.svg -o resources/MenuBarIcon.pdf
echo "Wrote resources/AppIcon.icns and resources/MenuBarIcon.pdf"
