# Glossar / Glossary

Begriffe und Schreibweisen für alle Texte in BarDrop, im README, im Changelog und in den Release-Notizen. Texte stehen im Code nebeneinander als `L("English", "Deutsch")`.

Terms and conventions for all texts in BarDrop, the README, the changelog and the release notes.

## Begriffe der App / App terms

| Deutsch | English | Bedeutung / Meaning |
|---|---|---|
| Ablage | shelf | Die schwarze Fläche am Bildschirmrand / the black panel at the screen edge |
| Streifen | strip | Erste, flache Stufe am Rand / first, thin stage at the edge |
| Rand, Bildschirmrand | edge, screen edge | |
| Objekt, Objekte | item, items | Alles in der Ablage: Dateien, Bilder aus dem Web, Links, Text / anything in the shelf |
| Datei | file | Nur für echte Dateien, z. B. aus dem Finder / only for actual files |
| Bilder aus dem Web | web images, images from the web | Kein „Webbild“ / not “web pictures” |
| Kopie | copy | Von BarDrop angelegte Kopie einer Datei / a copy BarDrop stores |
| Stapel | stack | Mehrere Objekte in einer Kachel / several items in one tile |
| Kachel | tile | Nur in Code und Kommentaren, nicht in Texten der App / code only |
| Aktionsleiste | action bar | |
| Aktion | action | AirDrop, Mail, Ordner, App … |
| Anheften | pin | Ordner oder App an die Aktionsleiste / folder or app to the action bar |
| Umwandeln | convert | |
| Ablegen | drop | |
| Herausziehen | drag out | |
| Entfernen | remove | Aus der Ablage nehmen, nicht löschen / take out of the shelf, not delete |
| Widerrufen, Wiederholen | undo, redo | |
| Einführung | introduction | |
| Tastaturkurzbefehl | keyboard shortcut | Der globale zum Öffnen der Ablage (Wort von macOS). Nicht „Kurzbefehl“, das ist die App Kurzbefehle / the global hotkey; not “shortcut”, that is the Shortcuts app |
| Kurzbefehl | shortcut | Nur ein Kurzbefehl aus der App Kurzbefehle (Aktion) / only a shortcut from the Shortcuts app (action) |
| Vom Rand abziehen, vom Rand abgezogen | pull off the edge, pulled off the edge | Die Ablage oben greifen und frei schweben lassen; nicht „losgelöst“ / grab the shelf at the top so it floats; not “detached” |
| Tastenkürzel | keyboard shortcuts | Die Tasten in der offenen Ablage / keys in the open shelf |
| Sondertaste | modifier key | |
| Zeiger | pointer | |
| Bildschirm | display | |
| Laufwerk | drive | |
| Einstellungen | Settings | Fenster der App / the app’s window |

## Begriffe von macOS / macOS terms

Immer wie in macOS selbst / always as macOS itself writes them.

| Deutsch | English |
|---|---|
| Systemeinstellungen | System Settings |
| Datenschutz & Sicherheit | Privacy & Security |
| Bedienungshilfen | Accessibility |
| Bewegung reduzieren | Reduce motion |
| Anmeldeobjekte | Login Items |
| Ordner „Programme“ | Applications folder |
| Papierkorb, In den Papierkorb legen | Trash, Move to Trash |
| Im Finder zeigen | Show in Finder |
| Übersicht | Quick Look |
| Leertaste | Space |
| Bildschirmfoto | screenshot |
| Nachrichten | Messages |
| Teilen | Share |
| Zwischenablage | clipboard |
| Vollbild | full screen |
| Softwareupdate | software update |

## Schreibweisen / Conventions

**Deutsch**
* Immer „du“, kleingeschrieben; Imperativ ohne Apostroph: „Zieh“, „Drück“, „Klick“, „Wähl“.
* Anführungszeichen „…“, Apostroph ’, Prozent mit Abstand: `Format.percent` („20 %“).
* Menüeinträge und Knöpfe ohne Artikel, wo es natürlich klingt: „Pfad kopieren“, „Aus Stapel lösen“.
* Zahl und Mehrzahl: „1 Objekt“, „2 Objekte“; die Einzahl ist immer ein eigener Text.

**English**
* American English: “color”, “gray”, “canceled”.
* Title Case for menu items and buttons (“Show in Finder”, “Group as Stack”, “Let’s Go”), sentence case for labels, switches, section titles, tooltips and running text.
* Quotation marks “…”, apostrophe ’, contractions like “can’t” and “isn’t”.
* Number and plural: “1 item”, “2 items”; the singular is always its own text.

**Beide / Both**
* Tasten als Symbole: ⌘ ⌥ ⌃ ⇧ ↩ ⌫ ←→↑↓, in dieser Reihenfolge der Sondertasten: `⌃⌥⇧⌘`. Escape als „esc“.
* Wege durch die Oberfläche mit Pfeil: „Einstellungen → Über BarDrop“ / “Settings → About BarDrop”.
* Keine Auslassungspunkte in Menüs und Knöpfen (auch nicht für Einträge, die ein Fenster öffnen). Das prüft `scripts/check_project.py`.
* Zahlen, Zeiten und Grenzen in Texten müssen dem Code entsprechen. Wer einen Wert ändert, sucht nach ihm in allen Texten, im README und in den Release-Notizen.
* Deutsche und englische Fassung sagen inhaltlich genau dasselbe.
