#!/bin/bash
# Builds "Swap Island.app" for Apple Silicon and Intel. The app is a thin UI over the cswap CLI,
# so it needs no entitlements, only a bundle identity (LSUIElement keeps it out of the Dock).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.3}"
BUILD_FLAGS=(-c release --arch arm64 --arch x86_64)

swift build "${BUILD_FLAGS[@]}"
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/SwapIsland"

APP="build/Swap Island.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SwapIsland"
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Swap Island</string>
  <key>CFBundleDisplayName</key><string>Swap Island</string>
  <key>CFBundleIdentifier</key><string>ai.liberators.swapisland</string>
  <key>CFBundleExecutable</key><string>SwapIsland</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
