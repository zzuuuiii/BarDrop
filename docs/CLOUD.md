# Setting up cloud services

**English** · [Deutsch](CLOUD.de.md)

Settings → Cloud uploads files into a “BarDrop Share” folder and puts the link on the clipboard or into the shelf as an item. iCloud Drive needs nothing: it uses your Mac’s iCloud Drive. For Dropbox, Google Drive and OneDrive, BarDrop has to be registered as an app with each provider **once**. That’s free. After that, Info.plist holds one ID per provider, and every user signs in with their own account in the browser.

The IDs aren’t secret (every desktop app ships them). They’re in `Resources/Info.plist`:

| Key | Provider |
|---|---|
| `BarDropCloudDropboxKey` | Dropbox: “App key” |
| `BarDropCloudGoogleClientID`, `BarDropCloudGoogleClientSecret` | Google: “Client ID” and “Client secret” |
| `BarDropCloudMicrosoftClientID` | Microsoft: “Application (client) ID” |

To try it without building, you can also use `defaults write com.zzuuuiii.bardrop BarDropCloudDropboxKey <key>` (then restart BarDrop).

BarDrop receives the sign-in response on your own Mac, on port **53682** (reachable only locally).

## Dropbox

1. https://www.dropbox.com/developers/apps → **Create app**.
2. **Scoped access**, **Full Dropbox** (so the “BarDrop Share” folder sits at the top of Dropbox; “App folder” works too, then it’s under “Apps”), name for example “BarDrop”.
3. **Permissions** tab: check `account_info.read`, `files.content.write`, `files.content.read` (for the copy of “BarDrop Share” on your Mac), `sharing.write`, `sharing.read`, then **Submit**.
4. **Settings** tab → **Redirect URIs**: enter exactly `http://127.0.0.1:53682/` (Dropbox checks the port too).
5. Put the **App key** into `BarDropCloudDropboxKey`. The “App secret” isn’t needed (PKCE).
6. While the app is in development mode at Dropbox, up to 500 users can sign in. For more: **Apply for production**.

## Google Drive

1. https://console.cloud.google.com → new project “BarDrop”.
2. **APIs & Services → Library** → “Google Drive API” → **Enable**.
3. **OAuth consent screen** (Google Auth Platform): type **External**, app name, support email. Under **Data Access**, add the scope `.../auth/drive.file` (not “drive”: `drive.file` isn’t sensitive and needs no yearly review). For testing, add your own accounts under **Audience → Test users**; for everyone, **Publish app** later.
4. **Clients → Create client** → type **Desktop app**.
5. Put the **Client ID** and **Client secret** into the two Google keys. According to Google, the secret of a desktop app isn’t confidential, but it’s required for signing in.

## OneDrive (Microsoft)

1. https://entra.microsoft.com → **App registrations → New registration**.
2. **Supported account types**: “Accounts in any organizational directory and personal Microsoft accounts” (personal accounts and work or school accounts).
3. **Redirect URI**: platform **Public client/native (mobile & desktop)**, address `http://localhost` (Microsoft ignores the port).
4. **Authentication** → **Allow public client flows**: Yes.
5. **API permissions** → Microsoft Graph, Delegated: `Files.ReadWrite`, `User.Read`, `offline_access`.
6. Put the **Application (client) ID** into `BarDropCloudMicrosoftClientID`. There is no secret.

Some companies turn off links “for anyone”. Then BarDrop creates a link for your own organization.

## iCloud Drive

Nothing to register. macOS creates the link itself as soon as the file is uploaded (which is why it takes a while for large files). iCloud links expire after about 30 days.
