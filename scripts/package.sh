#!/bin/bash
# Produces the release assets in dist/. The names carry no version, so the install script and the
# README can link to /releases/latest/download/ and never go stale.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh

APP="build/Swap Island.app"
rm -rf dist
mkdir -p dist

ditto -c -k --keepParent "$APP" dist/Swap-Island.zip

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Swap Island" -srcfolder "$STAGE" -ov -format UDZO dist/Swap-Island.dmg
rm -rf "$STAGE"

(cd dist && shasum -a 256 Swap-Island.zip > Swap-Island.zip.sha256 && shasum -a 256 Swap-Island.dmg > Swap-Island.dmg.sha256)
ls -lh dist
