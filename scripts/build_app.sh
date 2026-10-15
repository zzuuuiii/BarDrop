#!/bin/bash
# Baut BarDrop.app (Universal: Apple Silicon + Intel) und BarDrop.dmg.
# Läuft auf macOS mit Xcode bzw. den Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="BarDrop"
VERSION="$(cat Resources/VERSION | tr -d '[:space:]')"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
OUT="build"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Kompiliere $APP $VERSION ($BUILD_NUMBER)"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> Erzeuge App-Bundle"
APP_DIR="$OUT/$APP.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP" "$APP_DIR/Contents/MacOS/$APP"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" Resources/Info.plist > "$APP_DIR/Contents/Info.plist"
printf "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "==> Erzeuge App-Icon"
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Signiere (ad hoc)"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --verbose "$APP_DIR"

echo "==> Erzeuge DMG"
# Installationsfenster mit Hintergrund und Pfeil (dmgbuild schreibt die Anordnung
# direkt, ohne den Finder fernzusteuern). Fällt das aus, gibt es die schlichte Variante.
tiffutil -cathidpicheck Resources/dmg-background.png Resources/dmg-background@2x.png \
  -out "$OUT/dmg-background.tiff" >/dev/null
if python3 -m venv "$OUT/venv" && "$OUT/venv/bin/pip" install --quiet dmgbuild; then
  "$OUT/venv/bin/dmgbuild" -s scripts/dmg_settings.py \
    -D app="$APP_DIR" -D background="$OUT/dmg-background.tiff" \
    "$APP" "$OUT/$APP.dmg"
else
  echo "::warning::dmgbuild nicht verfügbar, schlichtes DMG"
  STAGE="$OUT/dmg"
  mkdir -p "$STAGE"
  cp -R "$APP_DIR" "$STAGE/"
  ln -s /Applications "$STAGE/Programme"
  hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$APP.dmg"
fi

lipo -info "$APP_DIR/Contents/MacOS/$APP"
echo "==> Fertig: $OUT/$APP.dmg"
