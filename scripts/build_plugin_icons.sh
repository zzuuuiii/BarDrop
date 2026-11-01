#!/bin/bash
# Symbole für .bdrop-Dateien in ein fertiges App-Bundle legen:
#
#     scripts/build_plugin_icons.sh pfad/BarDrop.app [arm64 x86_64]
#
# 1. PluginDocument.icns: festes Dokumentsymbol (Blatt mit grauem Puzzleteil), steht in der
#    Info.plist. macOS zeigt es, solange noch keine Vorschau da ist.
# 2. BarDropThumbnails.appex: Quick-Look-Erweiterung, die jeder .bdrop-Datei das Symbol ihres
#    Plugins gibt (Farbe und Zeichen aus der manifest.json), wie bei DMG-Dateien auf dem Blatt.
#
# Die Erweiterung wird mit swiftc gebaut, nicht als Ziel in Package.swift: SwiftPM gibt jedem
# Programm ein eigenes main, und ExtensionKit ruft main beim Start auf. Mit main, das selbst
# NSExtensionMain aufruft, lief das im Test endlos im Kreis (Absturz, Stapel voll). Ohne main
# und mit _NSExtensionMain als Einstieg ist es so gebaut wie von Xcode.
# Signiert wird danach in scripts/sign_app.sh (die Erweiterung braucht die Sandbox).
set -euo pipefail

cd "$(dirname "$0")/.."
APP_DIR="$1"
shift
ARCHS=("$@")
[ ${#ARCHS[@]} -eq 0 ] && ARCHS=("$(uname -m)")
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
PLIST="$APP_DIR/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Erzeuge Symbol für .bdrop-Dateien"
ICONSET="$WORK/PluginDocument.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/PluginDocument.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Resources/PluginDocument.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/PluginDocument.icns"

echo "==> Kompiliere Quick-Look-Erweiterung (${ARCHS[*]})"
EXT="$APP_DIR/Contents/PlugIns/BarDropThumbnails.appex"
rm -rf "$EXT"
mkdir -p "$EXT/Contents/MacOS"
BINARIES=()
for arch in "${ARCHS[@]}"; do
  swiftc -O -parse-as-library -application-extension -module-name BarDropThumbnails \
    -sdk "$SDK" -target "$arch-apple-macos14.0" \
    -Xlinker -application_extension -Xlinker -e -Xlinker _NSExtensionMain \
    Extensions/Thumbnails/*.swift -o "$WORK/BarDropThumbnails-$arch"
  BINARIES+=("$WORK/BarDropThumbnails-$arch")
done
lipo -create "${BINARIES[@]}" -output "$EXT/Contents/MacOS/BarDropThumbnails"
# Kennung der Erweiterung muss mit der Kennung der App beginnen
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__SHORT__/$SHORT/g" -e "s/__BUILD__/$BUILD/g" \
    Extensions/Thumbnails/Info.plist > "$EXT/Contents/Info.plist"
