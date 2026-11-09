#!/bin/zsh
# Builds GoProConnector and creates the "GoPro Connector.app" bundle in the build/ folder.
# Usage: scripts/build-app.sh [--install]
#   --install  installs the app in /Applications (it shows up in Launchpad) and removes the copy in build/
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="GoPro Connector"
BUNDLE="build/${APP_NAME}.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[[ -f Resources/AppIcon.icns ]] || swift tools/make_icon.swift Resources/AppIcon.icns

swift build -c release
BIN="$(swift build -c release --show-bin-path)/GoProConnector"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/GoProConnector"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"
cp -R Resources/*.lproj "$BUNDLE/Contents/Resources/"   # translations (English base + Italian)

# Ad-hoc signature: needed for the local network permission on macOS 15
codesign --force --deep --sign - "$BUNDLE"

echo "Created: $BUNDLE"
if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/${APP_NAME}.app"
  pkill -x GoProConnector 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  ditto "$BUNDLE" "$DEST"
  # Keep a single registered copy, so Launchpad/Spotlight always open the installed one
  "$LSREGISTER" -u "$BUNDLE" 2>/dev/null || true
  rm -rf "$BUNDLE"
  "$LSREGISTER" -f "$DEST"
  touch "$DEST"
  echo "Installed: $DEST (visible in Launchpad)"
fi
