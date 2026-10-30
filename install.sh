#!/bin/bash
# Installs the latest Swap Island release, plus cswap if it is missing.
# curl sets no quarantine flag, so this route needs no Gatekeeper override.
set -euo pipefail

RELEASE="https://github.com/liberators-ai/swap-island/releases/latest/download"
ASSET="Swap-Island.zip"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Swap Island runs on macOS only." >&2
  exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]; then
  echo "Swap Island needs macOS 14 or later." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading Swap Island..."
curl -fsSL "$RELEASE/$ASSET" -o "$WORK/$ASSET"
curl -fsSL "$RELEASE/$ASSET.sha256" -o "$WORK/$ASSET.sha256"
(cd "$WORK" && shasum -a 256 -c "$ASSET.sha256" >/dev/null)
ditto -x -k "$WORK/$ASSET" "$WORK/unpacked"

if [ -w /Applications ]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

pkill -x SwapIsland 2>/dev/null || true
rm -rf "$DEST/Swap Island.app"
ditto "$WORK/unpacked/Swap Island.app" "$DEST/Swap Island.app"
echo "Installed $DEST/Swap Island.app"

if command -v cswap >/dev/null 2>&1 || [ -x "$HOME/.local/bin/cswap" ]; then
  echo "Found cswap."
elif command -v uv >/dev/null 2>&1; then
  echo "Installing cswap with uv..."
  uv tool install claude-swap
elif command -v pipx >/dev/null 2>&1; then
  echo "Installing cswap with pipx..."
  pipx install claude-swap
else
  echo "cswap is missing, and neither uv nor pipx is installed."
  echo "Swap Island shows the install command when it opens."
fi

open "$DEST/Swap Island.app"
echo "Done. Move the pointer to the notch, or click the menu bar icon."
