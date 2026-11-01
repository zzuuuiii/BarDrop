#!/bin/bash
# Signiert BarDrop.app. Mit fester Signatur, wenn ein Zertifikat da ist, sonst ad hoc.
#
#     scripts/sign_app.sh pfad/BarDrop.app
#
# Warum: Ad hoc erkennt macOS die App am Fingerabdruck ihres Codes. Jede neue Fassung ist für
# macOS eine andere App und fragt Freigaben wie den Zugriff auf den Schreibtisch neu ab (bei
# Johann nach jedem Update, sogar doppelt). Mit einem festen Zertifikat erkennt macOS die App
# an der Unterschrift und behält die Freigaben über Updates.
#
# Woher das Zertifikat kommt (der Reihe nach):
# 1. GitHub Actions: Geheimnisse BARDROP_SIGNING_P12 (Base64 der .p12) und
#    BARDROP_SIGNING_PASSWORD. Es wird in einen eigenen Schlüsselbund nur für diesen Lauf geladen.
# 2. Auf dem Mac: Identität „BarDrop Signatur“ im Schlüsselbund (angelegt mit
#    scripts/create_signing_identity.sh bzw. „Signatur einrichten.command“).
# 3. Sonst ad hoc wie bisher.
set -euo pipefail
# Variablen vor typografischen Anführungszeichen immer in {}: Per Doppelklick im Finder läuft
# bash ohne UTF-8 und las „$NAME“ als Variable „NAME\xe2…“ (unbound variable). Dann brach das
# Signieren ab, die App blieb unsigniert, und macOS fragte Freigaben wieder und wieder ab

APP_DIR="$1"
NAME="BarDrop Signatur"
IDENTITY="-"
TEMP_KEYCHAIN=""
P12=""

ORIGINAL_KEYCHAINS="$(security list-keychains -d user | tr -d '"')"
cleanup() {
  # Auch wenn der Import scheitert: die entschlüsselte Zertifikatsdatei nicht liegen lassen
  if [ -n "$P12" ]; then rm -f "$P12"; fi
  if [ -n "$TEMP_KEYCHAIN" ]; then
    # Suchliste wie vorher (auf einem Mac sonst bliebe der gelöschte Schlüsselbund darin)
    security list-keychains -d user -s $ORIGINAL_KEYCHAINS
    security delete-keychain "$TEMP_KEYCHAIN" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ -n "${BARDROP_SIGNING_P12:-}" ] && [ -n "${BARDROP_SIGNING_PASSWORD:-}" ]; then
  TEMP_KEYCHAIN="${RUNNER_TEMP:-$(mktemp -d)}/bardrop-signing.keychain-db"
  KEYCHAIN_PASSWORD="$(uuidgen)"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$TEMP_KEYCHAIN"
  security set-keychain-settings -lut 3600 "$TEMP_KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$TEMP_KEYCHAIN"
  P12="$(dirname "$TEMP_KEYCHAIN")/signing.p12"
  printf '%s' "$BARDROP_SIGNING_P12" | base64 --decode > "$P12"
  security import "$P12" -k "$TEMP_KEYCHAIN" -P "$BARDROP_SIGNING_PASSWORD" -T /usr/bin/codesign >/dev/null
  rm -f "$P12"
  # codesign darf den Schlüssel ohne Rückfrage benutzen
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$TEMP_KEYCHAIN" >/dev/null
  # Schlüsselbund in die Suchliste, damit codesign die Identität findet
  security list-keychains -d user -s "$TEMP_KEYCHAIN" $ORIGINAL_KEYCHAINS
  IDENTITY="$NAME"
elif security find-certificate -c "$NAME" >/dev/null 2>&1; then
  IDENTITY="$NAME"
fi

if [ "$IDENTITY" = "-" ]; then
  echo "==> Signiere (ad hoc, kein Zertifikat „${NAME}“)"
else
  echo "==> Signiere mit „${NAME}“"
fi
# Erweiterungen zuerst und einzeln, mit ihren Rechten (Quick Look startet sie nur in der
# Sandbox). --deep an der App hätte sie ohne Rechte neu signiert
for EXT in "$APP_DIR"/Contents/PlugIns/*.appex; do
  [ -d "$EXT" ] || continue
  # BarDropThumbnails.appex → Extensions/Thumbnails/Thumbnails.entitlements
  EXT_NAME="$(basename "$EXT" .appex)"
  EXT_NAME="${EXT_NAME#BarDrop}"
  codesign --force --sign "$IDENTITY" ${TEMP_KEYCHAIN:+--keychain "$TEMP_KEYCHAIN"} \
    --entitlements "$(dirname "$0")/../Extensions/${EXT_NAME}/${EXT_NAME}.entitlements" "$EXT"
done
codesign --force --sign "$IDENTITY" ${TEMP_KEYCHAIN:+--keychain "$TEMP_KEYCHAIN"} "$APP_DIR"
codesign --verify --deep --verbose "$APP_DIR"
