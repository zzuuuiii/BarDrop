# Cloud-Dienste einrichten

[English](CLOUD.md) · **Deutsch**

Einstellungen → Cloud lädt Dateien in einen Ordner „BarDrop Share“ und legt den Link in die Zwischenablage oder als Objekt in die Ablage. iCloud Drive braucht nichts: Es nutzt iCloud Drive des Mac. Für Dropbox, Google Drive und OneDrive muss BarDrop **einmal** beim jeweiligen Anbieter als App eingetragen werden. Das ist kostenlos. Danach steht in der Info.plist je eine Kennung, und jeder Nutzer meldet sich mit seinem eigenen Konto im Browser an.

Die Kennungen sind nicht geheim (jede Desktop-App liefert sie mit). Sie stehen in `Resources/Info.plist`:

| Schlüssel | Anbieter |
|---|---|
| `BarDropCloudDropboxKey` | Dropbox: „App key“ |
| `BarDropCloudGoogleClientID`, `BarDropCloudGoogleClientSecret` | Google: „Client ID“ und „Client secret“ |
| `BarDropCloudMicrosoftClientID` | Microsoft: „Application (client) ID“ |

Zum Ausprobieren ohne Bauen geht auch `defaults write com.zzuuuiii.bardrop BarDropCloudDropboxKey <key>` (dann BarDrop neu starten).

BarDrop nimmt die Rückmeldung der Anmeldung auf dem eigenen Mac an, auf Port **53682** (nur lokal erreichbar).

## Dropbox

1. https://www.dropbox.com/developers/apps → **Create app**.
2. **Scoped access**, **Full Dropbox** (damit der Ordner „BarDrop Share“ oben in Dropbox liegt; „App folder“ ginge auch, dann liegt er unter „Apps“), Name z. B. „BarDrop“.
3. Reiter **Permissions**: `account_info.read`, `files.content.write`, `files.content.read` (für die Kopie von „BarDrop Share“ auf dem Mac), `sharing.write`, `sharing.read` anhaken, **Submit**.
4. Reiter **Settings** → **Redirect URIs**: genau `http://127.0.0.1:53682/` eintragen (Dropbox prüft den Port mit).
5. **App key** in `BarDropCloudDropboxKey`. Das „App secret“ wird nicht gebraucht (PKCE).
6. Solange die App bei Dropbox im Entwicklungsmodus ist, können sich bis zu 500 Nutzer anmelden. Für mehr: **Apply for production**.

## Google Drive

1. https://console.cloud.google.com → neues Projekt „BarDrop“.
2. **APIs & Services → Library** → „Google Drive API“ → **Enable**.
3. **OAuth consent screen** (Google Auth Platform): Typ **External**, App-Name, Support-E-Mail. Bei **Data Access** den Bereich `.../auth/drive.file` hinzufügen (nicht „drive“: `drive.file` ist nicht sensibel und braucht keine jährliche Prüfung). Zum Testen eigene Konten unter **Audience → Test users** eintragen; für alle später **Publish app**.
4. **Clients → Create client** → Typ **Desktop app**.
5. **Client ID** und **Client secret** in die beiden Google-Schlüssel. Bei Desktop-Apps ist das Secret laut Google nicht vertraulich, wird aber beim Anmelden verlangt.

## OneDrive (Microsoft)

1. https://entra.microsoft.com → **App registrations → New registration**.
2. **Supported account types**: „Accounts in any organizational directory and personal Microsoft accounts“ (private Konten und Konten von Firma oder Schule).
3. **Redirect URI**: Plattform **Public client/native (mobile & desktop)**, Adresse `http://localhost` (der Port zählt bei Microsoft nicht).
4. **Authentication** → **Allow public client flows**: Ja.
5. **API permissions** → Microsoft Graph, Delegated: `Files.ReadWrite`, `User.Read`, `offline_access`.
6. **Application (client) ID** in `BarDropCloudMicrosoftClientID`. Ein Secret gibt es nicht.

Manche Firmen schalten Links „für alle“ ab. Dann erzeugt BarDrop einen Link für die eigene Organisation.

## iCloud Drive

Kein Eintrag nötig. Den Link erzeugt macOS selbst, sobald die Datei hochgeladen ist (darum dauert es bei großen Dateien). iCloud-Links laufen nach etwa 30 Tagen ab.
