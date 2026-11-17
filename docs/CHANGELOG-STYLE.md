# Changelog: so wird er geschrieben

Gilt ab 1.31.0 Beta 12 für `CHANGELOG.md`, `.github/RELEASE_NOTES.md` und den Entwurf in `Arbeitsablauf.md`. Ältere Einträge bleiben, wie sie sind.

## Sprache

Nur Englisch, auch in den Release-Notizen (kein deutscher Teil mehr). Begriffe wie in `docs/GLOSSARY.md`. Geschrieben für Nutzer: was sich für sie ändert und wo sie es finden, keine Dateinamen, Klassen oder Messwerte, außer sie sagen dem Nutzer etwas.

## Aufbau eines Eintrags

```markdown
## 1.31.0-beta.12

### New
* **Stacks by dragging.** Drag an item onto another and hold it for a moment to make a stack.

### Changed
* **Width in columns.** Width in Settings now counts columns, and changing the item size keeps them.

### Fixed
* **Cloud sign-in.** Other web pages can no longer cancel it, and an expired sign-in asks you to connect again.

### Removed
* **Old open delays.** The 4 and 5 second delays are gone.
```

- Die Überschrift ist genau die Nummer aus `Resources/VERSION` (prüft `scripts/check_project.py`).
- Nur diese vier Abschnitte, immer in dieser Reihenfolge: **New, Changed, Fixed, Removed**. Leere Abschnitte fallen weg. Keine weiteren wie „Highlights“ oder „Plugins“: Plugin-Änderungen kommen in den passenden Abschnitt.
- Innerhalb eines Abschnitts: zuerst, was die meisten Nutzer bemerken.
- Jeder Punkt: `* **Titel.** Text`
  - Titel: 2 bis 6 Wörter, nur der erste Buchstabe groß, endet mit Punkt. Er steht allein für die Änderung (die Website zeigt ihn als Kurzfassung).
  - Text: 1 bis 2 Sätze, zusammen höchstens etwa 220 Zeichen. Wo es sitzt mit Pfeil (`Settings → Items → …`), Tasten in Backticks (`⌘D`), Issue-Nummer am Ende in Klammern (`(#58)`).

## Wie viel

- **Beta:** nur was seit der letzten Beta neu ist, höchstens 10 Punkte. Viele kleine Korrekturen in einen Punkt pro Bereich zusammenfassen (`* **Smaller fixes in the shelf.** …`).
- **Stabile Version** (z. B. `## 1.31.0`): ein eigener Eintrag über allen Betas seit der letzten stabilen Version, höchstens 12 Punkte: das Wichtigste aus New, dann Changed, Fixed nach Bereichen gebündelt. Die Beta-Einträge darunter bleiben.
- Nicht hinein: rein interne Arbeit (Umbau im Code, Tests, CI, Skripte). Ausnahme: was Plugin-Entwickler betrifft, als Punkt unter Changed, Titel beginnt mit `For plugin developers:`.

## Release-Notizen

`.github/RELEASE_NOTES.md` ist der Text des GitHub-Release und erscheint in BarDrop unter „Neuigkeiten“. Englisch, ohne Überschrift, 3 bis 6 Punkte im selben Format `* **Titel.** Text`: die wichtigsten aus dem Eintrag, wörtlich übernommen oder gekürzt. Keine Marke `<!-- de -->` mehr.

## Während der Arbeit

Jede sichtbare Änderung gleich in den Entwurf in `Arbeitsablauf.md` schreiben, schon in die vier Abschnitte sortiert und im Format oben. Ändert sich etwas wieder, den bestehenden Punkt anpassen statt einen zweiten anzufügen. Beim Veröffentlichen wird der Entwurf nur noch gekürzt und übernommen.
