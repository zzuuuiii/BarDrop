#!/bin/bash
# App-Symbol ins Bundle: AppIcon.icns aus Resources/AppIcon.png (für macOS 14 und 15) und
# Assets.car aus Resources/AppIcon.icon (Icon Composer). Ab macOS 26 nimmt das System das
# Symbol aus Assets.car (CFBundleIconName) und legt es nicht mehr in eine graue Kachel.
# Aufruf: scripts/compile_app_icon.sh <App-Bundle> <Arbeitsordner>
set -euo pipefail
APP_DIR="$1"
WORK="$2"
RES="$APP_DIR/Contents/Resources"
# Quellen aus dem Repo, egal aus welchem Ordner das Skript aufgerufen wird
# (Bundle und Arbeitsordner bleiben wie übergeben)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

# .icon-Dokumente übersetzt actool erst ab Xcode 26; ohne bleibt es beim bisherigen Symbol.
# Erfolg nur, wenn das App-Symbol wirklich im Katalog steht (CFBundleIconName in der
# Teil-Info.plist von actool), sonst zeigte CFBundleIconName auf ein fehlendes Symbol
CAR="$WORK/AppIcon-car"
rm -rf "$CAR" && mkdir -p "$CAR"
if xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$CAR" --platform macosx \
     --minimum-deployment-target 14.0 --app-icon AppIcon \
     --output-partial-info-plist "$CAR/info.plist" >"$WORK/actool.log" 2>&1 \
   && [ -f "$CAR/Assets.car" ] \
   && /usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$CAR/info.plist" >/dev/null 2>&1; then
  cp "$CAR/Assets.car" "$RES/Assets.car"
else
  # Als Warnung samt Ausgabe von actool, damit es im Release-Lauf auffällt
  # (sonst wieder die graue Kachel ab macOS 26, ohne dass der Build scheitert)
  echo "::warning::Assets.car nicht erzeugt (actool fehlt oder scheiterte), nur AppIcon.icns."
  tail -20 "$WORK/actool.log" >&2 || true
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi
