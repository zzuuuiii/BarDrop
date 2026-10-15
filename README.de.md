<p align="center">
  <img src="Resources/AppIcon.png" width="112" alt="BarDrop">
</p>

<h1 align="center">BarDrop</h1>

<p align="center">
  Eine unsichtbare Ablage am Rand deines Bildschirms.<br>
  <sub><a href="README.md">English</a> · <b>Deutsch</b></sub>
</p>

<p align="center">
  <a href="https://github.com/zzuuuiii/BarDrop/releases/latest/download/BarDrop.dmg"><b>Herunterladen</b></a>
  &nbsp;·&nbsp;
  <sub>macOS 14 oder neuer · Apple Silicon & Intel · kostenlos und quelloffen</sub>
</p>

<p align="center">
  <img src="docs/preview.gif" width="660" alt="Eine Datei wird an den Bildschirmrand gezogen, die Ablage öffnet sich und nimmt sie auf; später wird sie in eine E-Mail gezogen">
</p>

## So funktioniert es

1. **Zieh eine Datei an den Rand** deines Bildschirms. Die Ablage öffnet sich und behält sie.
2. **Wechsle in eine beliebige App.**
3. **Fahr mit dem Zeiger an den Rand** und zieh die Datei wieder heraus.

Klappt mit Dateien, Ordnern, Bildern aus dem Web, Links und Text. Beim ersten Start zeigt eine kurze Einführung jeden Schritt.

## Installieren

[BarDrop.dmg herunterladen](https://github.com/zzuuuiii/BarDrop/releases/latest/download/BarDrop.dmg), öffnen und BarDrop in „Programme“ ziehen. Updates kommen über die App.

<details>
<summary><sub>macOS meldet, dass BarDrop nicht geprüft werden kann?</sub></summary>
<br>

Das erscheint bei jeder App, die nicht über Apples kostenpflichtiges Entwicklerprogramm notarisiert ist; gefunden wurde nichts. Die DMG baut [GitHub Actions](https://github.com/zzuuuiii/BarDrop/actions) direkt aus diesem Code. Einmalig freigeben unter **Systemeinstellungen → Datenschutz & Sicherheit → Trotzdem öffnen**.

</details>

<details>
<summary><sub>Funktionen</sub></summary>
<br>

* Linker oder rechter Rand, feste Höhe oder dort, wo der Zeiger den Rand erreicht
* Öffnet sofort, nach kurzer Wartezeit, per Klick oder Kurzbefehl (`⌃⌥B`)
* Aktionsleiste für AirDrop, Mail, Nachrichten, beliebige Ordner und Apps, in einer oder zwei Reihen
* Stapel, Übersicht (Quick Look), Auswahl wie im Finder, `⌘Z` zum Widerrufen
* Findet verschobene und umbenannte Dateien wieder, lädt iCloud-Dateien bei Bedarf
* Räumt auf Wunsch nach einer gewählten Zeit auf, übersteht Neustarts
* Englisch und Deutsch, kein Menüleistensymbol, im Ruhezustand praktisch kein Energieverbrauch

</details>

<details>
<summary><sub>Tastatur</sub></summary>
<br>

| Taste | Aktion |
|---|---|
| `⌃⌥B` | Ablage ein- oder ausblenden (änderbar) |
| Leertaste, `⌘Y` | Übersicht |
| `↩`, `⌘O` | Öffnen |
| `⌘R` | Im Finder zeigen |
| `⌘A`, `⌘C`, `⌥⌘C`, `⌘V` | Alle auswählen, kopieren, Pfad kopieren, einfügen |
| `⌫`, `⌘Z`, `⇧⌘Z` | Entfernen, widerrufen, wiederholen |
| `⌘,`, `⌘Q` | Einstellungen, beenden |
| `esc` | Auswahl aufheben, Stapel verlassen, schließen |

</details>

<details>
<summary><sub>Datenschutz</sub></summary>
<br>

BarDrop sammelt keine Daten. Die Ablage liegt nur auf deinem Mac unter `~/Library/Application Support/BarDrop`. Die einzige Verbindung ist die Suche nach Updates bei GitHub, und die lässt sich abschalten.

</details>

<details>
<summary><sub>Selbst bauen</sub></summary>
<br>

```bash
git clone https://github.com/zzuuuiii/BarDrop.git
cd BarDrop
./scripts/build_app.sh   # build/BarDrop.app und build/BarDrop.dmg
swift test
```

Benötigt macOS 14 und Xcode 15 oder neuer. Jeder Push auf `main` baut, testet und veröffentlicht die Version aus [`VERSION`](VERSION).

</details>

## Danke

Inspiriert von [Alcove](https://tryalcove.com) und [Klack](https://tryklack.com), mit Code aus [boring.notch](https://github.com/TheBoredTeam/boring.notch) und [perch](https://github.com/hausfold/perch). Details in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Keine Verbindung zu diesen Projekten.

<sub>[Änderungen (englisch)](CHANGELOG.md) · [Mitmachen](CONTRIBUTING.md) · [Sicherheit](SECURITY.md) · © 2026 zzuuuiii · [GPL-3.0](LICENSE)</sub>
