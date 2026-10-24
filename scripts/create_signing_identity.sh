#!/bin/bash
# Legt das feste Signatur-Zertifikat „BarDrop Signatur“ an (einmal, nur auf Johanns Mac) oder
# importiert eine vorhandene .p12 auf einem weiteren Mac.
#
#     scripts/create_signing_identity.sh              # neu anlegen
#     scripts/create_signing_identity.sh datei.p12    # vorhandenes importieren (fragt das Passwort)
#
# Selbst ausgestellt, kostenlos, ohne Apple-Konto, 20 Jahre gültig. Es ersetzt keine Developer
# ID: Gatekeeper warnt beim ersten Öffnen weiter. Es sorgt nur dafür, dass macOS Freigaben
# (Schreibtisch usw.) über Updates behält, siehe scripts/sign_app.sh.
#
# Der geheime Schlüssel landet im Anmelde-Schlüsselbund und als .p12 in
# ~/Library/Application Support/BarDrop-Signatur, NIE im Repository oder im geteilten iCloud-
# Ordner: Wer ihn hat, könnte Apps bauen, die macOS für BarDrop hält.
set -euo pipefail

NAME="BarDrop Signatur"
OUT="$HOME/Library/Application Support/BarDrop-Signatur"
# Das OpenSSL von macOS (LibreSSL): Dessen .p12 kann „security import“ lesen
OPENSSL=/usr/bin/openssl

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "„$NAME“ ist in deinem Schlüsselbund schon vorhanden. Nichts zu tun."
  exit 0
fi

if [ $# -ge 1 ]; then
  read -r -s -p "Passwort der .p12: " PASSWORD; echo
  security import "$1" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASSWORD" -T /usr/bin/codesign
  echo "Importiert. „Testversion installieren“ signiert ab jetzt mit „$NAME“."
  exit 0
fi

mkdir -p "$OUT"
chmod 700 "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

PASSWORD="$(uuidgen)"
"$OPENSSL" req -new -x509 -newkey rsa:3072 -nodes -days 7300 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -passout "pass:$PASSWORD" -out "$OUT/BarDrop-Signatur.p12"
chmod 600 "$OUT/BarDrop-Signatur.p12"

security import "$OUT/BarDrop-Signatur.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASSWORD" -T /usr/bin/codesign

# Für GitHub: Inhalt der beiden Geheimnisse
base64 -i "$OUT/BarDrop-Signatur.p12" > "$OUT/BARDROP_SIGNING_P12.txt"
printf '%s' "$PASSWORD" > "$OUT/BARDROP_SIGNING_PASSWORD.txt"
chmod 600 "$OUT"/*.txt

echo
echo "Fertig. „$NAME“ liegt in deinem Schlüsselbund."
echo "Für GitHub (Repository → Settings → Secrets and variables → Actions → New repository secret):"
echo "  BARDROP_SIGNING_P12      = Inhalt von $OUT/BARDROP_SIGNING_P12.txt"
echo "  BARDROP_SIGNING_PASSWORD = Inhalt von $OUT/BARDROP_SIGNING_PASSWORD.txt"
echo "Die Dateien danach gut aufbewahren (z. B. im Passwort-Manager) und nicht weitergeben."
open "$OUT"
