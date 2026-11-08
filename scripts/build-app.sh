#!/bin/zsh
# Compila GoProConnector e crea il bundle "GoPro Connector.app" nella cartella build/.
# Uso: scripts/build-app.sh [--install]
#   --install  installa l'app in /Applications (compare nel Launchpad) e rimuove la copia in build/
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

# Firma ad-hoc: necessaria per i permessi di rete locale su macOS 15
codesign --force --deep --sign - "$BUNDLE"

echo "Creato: $BUNDLE"
if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/${APP_NAME}.app"
  pkill -x GoProConnector 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  ditto "$BUNDLE" "$DEST"
  # Una sola copia registrata, così Launchpad/Spotlight aprono sempre quella installata
  "$LSREGISTER" -u "$BUNDLE" 2>/dev/null || true
  rm -rf "$BUNDLE"
  "$LSREGISTER" -f "$DEST"
  touch "$DEST"
  echo "Installato: $DEST (visibile nel Launchpad)"
fi
