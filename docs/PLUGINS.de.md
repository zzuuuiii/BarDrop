# Plugins für BarDrop: genaue Referenz

[English](PLUGINS.md) · Deutsch

Diese Datei beschreibt das Plugin-System von BarDrop vollständig und genau so, wie der Code es umsetzt (Stand 1.31.0 Beta 5). Was hier nicht steht, gibt es nicht. Wer ein Plugin schreibt, hält sich an diese Datei und prüft das Ergebnis mit `scripts/check_plugin.py` (Abschnitt 11).

Quellcode: `Sources/BarDrop/Plugins/`. Ändert sich dort etwas, wird diese Datei, ihre englische Fassung und `scripts/check_plugin.py` im selben Commit angepasst.

---

## 1. Überblick

* Ein Plugin ist **eine Datei mit der Endung `.bdrop`**. Darin steckt ein ZIP-Archiv mit `manifest.json` und einem JavaScript-Skript.
* BarDrop **bringt kein Plugin mit**. Plugins sind aus, bis der Nutzer unter Einstellungen → Plugins „Plugins verwenden“ einschaltet, und jedes Plugin ist danach einzeln aus.
* Ein Plugin bekommt **ein Objekt der Ablage** (Datei, Ordner oder Link). Alles, was es in seinen **Ausgabeordner** schreibt, wird zu **neuen Objekten direkt neben dem Original**.
* Gestartet wird ein Plugin auf drei Wegen: **Rechtsklick**, **Aktionsleiste** oder **automatisch beim Ablegen**.
* Das Skript läuft in **JavaScriptCore**. Es sieht nur das Objekt `bardrop`. Internet, Programme und Zwischenablage gibt es nur mit **Rechten**, die BarDrop vor dem ersten Lauf in **einem** Fenster erfragt (beim Import gilt „Installieren“ schon als Erlauben; Plugins aus der Galerie bekommen sie sofort).

## 2. Die .bdrop-Datei

| Regel | Wert |
| --- | --- |
| Format | ZIP-Archiv, Endung `.bdrop` |
| Größe | höchstens 5 MB (5 242 880 Byte), ausgepackt höchstens 20 MB |
| Aufbau | `manifest.json` direkt im Archiv **oder** in genau einem Ordner darin (versteckte Einträge und `__MACOSX` zählen nicht) |
| Skript | die Datei, die `script` im Manifest nennt; höchstens 1 MB; UTF-8 |
| Weitere Dateien | erlaubt (Texte, Vorlagen); das Skript liest sie mit `bardrop.readFile(bardrop.pluginDirectory + "/vorlage.txt")`. Der Import-Dialog nennt sie, und sie gehören zum Fingerabdruck (6). |
| Symbolische Verweise | werden beim Entpacken gelöscht |

Entpackt wird mit `/usr/bin/ditto`. Installiert liegt ein Plugin in `~/Library/Application Support/BarDrop/Plugins/<id>/`. Der Ordnername muss der `id` entsprechen.

**Erzeugen:** `python3 scripts/check_plugin.py MeinPlugin/ --pack` prüft den Ordner und erzeugt `MeinPlugin.bdrop`. Von Hand geht es mit `ditto -c -k --norsrc --noextattr MeinPlugin MeinPlugin.bdrop` oder mit „Komprimieren“ im Finder und anschließendem Umbenennen von `.zip` in `.bdrop`.

**Installieren:** Doppelklick auf die Datei oder Einstellungen → Plugins → Erweitert → „Importieren“. BarDrop zeigt Name, Rechte, nachzuladende Programme und das Skript, mit dem Hinweis, dass das Plugin nicht aus dem Katalog stammt. Installiert wird erst nach „Installieren“. Ist ein Plugin mit derselben `id` schon da, heißt der Knopf „Aktualisieren“. Ein Standard-Plugin aus dem Katalog lässt sich nicht durch einen Import ersetzen. Nach dem Import schaltet BarDrop „Plugins verwenden“ und das neue Plugin ein, eingestellt nach `defaults` (3.1). Ein Update lässt Ein/Aus und die Einstellungen, wie sie sind. Lässt sich ein installiertes Plugin nicht mehr lesen (etwa nach dem Bearbeiten), steht es mit der Fehlermeldung in der Liste, mit „Im Finder zeigen“ und, außer bei Standard-Plugins, „Entfernen“.

## 3. manifest.json

Unbekannte Schlüssel werden ignoriert. Ein Schlüssel mit falschem Typ (z. B. Zahl statt Text) macht das ganze Manifest unlesbar.

### 3.1 Alle Schlüssel

| Schlüssel | Typ | Pflicht | Bedeutung |
| --- | --- | --- | --- |
| `schema` | Zahl | nein | Muss `1` sein. Fehlt er, gilt 1. |
| `id` | Text | ja | Eindeutige Kennung, z. B. `io.github.name.mein-plugin`. Muster: `^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$`, also mindestens ein Punkt, nur Buchstaben, Ziffern, Bindestriche; höchstens 120 Zeichen. Bleibt bei Updates gleich. |
| `name` | Text (3.2) | ja | Name in Einstellungen und Dialogen. Der englische Text darf nicht leer sein. |
| `description` | Text (3.2) | nein | Steht oben auf der Seite des Plugins, in der Galerie und als Hilfetext der Aktion. |
| `version` | Text | ja | `1`, `1.2` oder `1.2.3`, als Text in Anführungszeichen. Muster `^\d+(\.\d+){0,2}$`. Keine Beta-Zusätze. |
| `author` | Text | nein | Wird neben der Version angezeigt. |
| `homepage` | Text | nein | Wird gespeichert, aber derzeit nicht angezeigt. |
| `icon` | Objekt | nein | `{"symbol": "…", "color": "#RRGGBB"}`, siehe 3.4. |
| `actionTitle` | Text (3.2) | nein | Titel im Rechtsklick und in der Aktionsleiste. Fehlt er, gilt `name`. |
| `minAppVersion` | Text | nein | Älteste BarDrop-Version, z. B. `"1.31.0"`. Verglichen wird ohne Beta-Zusatz: 1.31.0 Beta 2 zählt als 1.31.0. Ist BarDrop älter, wird das Plugin abgelehnt. Empfehlung: immer setzen. |
| `script` | Text | nein | Dateiname des Skripts, Standard `"main.js"`. Muss auf `.js` enden, darf keinen `/` enthalten und nicht mit `.` beginnen. |
| `match` | Objekt | ja | Wofür das Plugin zuständig ist, siehe 4. |
| `triggers` | Liste | nein | Teilmenge von `"menu"`, `"action"`, `"automatic"`. Fehlt der Schlüssel, gelten alle drei. Unbekannte Werte werden übergangen. Bleibt kein bekannter Wert übrig (auch bei `[]`), lehnt BarDrop das Plugin ab. |
| `automaticByDefault` | Wahrheitswert | nein | Älterer Schlüssel, besser `defaults.automatic`. „Automatisch beim Ablegen“ ist auch ohne Installieren und Erlauben an (Standard-Plugins aus dem Katalog), aber **nur**, wenn `triggers` `automatic` erlaubt und das Plugin weder `network` noch `run` noch `tools` hat. |
| `permissions` | Liste | nein | Teilmenge von `"network"`, `"run"`, `"clipboard"`, siehe 6. Ein **unbekannter** Wert lässt das ganze Plugin ablehnen. |
| `tools` | Liste | nein | Programme, die BarDrop nachlädt, siehe 7. Verlangt das Recht `run`. |
| `settings` | Liste | nein | Einstellungen des Plugins, siehe 3.3. |
| `canReplaceOriginal` | Wahrheitswert | nein | Zeigt den Schalter „Original ersetzen“ (Standard aus), siehe 8. Wirkt nicht zusammen mit `batch`. |
| `batch` | Wahrheitswert | nein | Bei mehreren Objekten **einmal** mit allen laufen statt je Objekt: `run(item, items)`, siehe 9.2. Das Ergebnis erscheint neben dem ersten Objekt. Gilt auch für zusammen abgelegte Objekte bei „Automatisch beim Ablegen“. |
| `consent` | Text (3.2) | nein | Hinweis, dem der Nutzer **einmal** zustimmen muss, bevor das Plugin eingeschaltet werden oder laufen kann. Ändert ein Update den Text, fragt BarDrop erneut. |
| `defaults` | Objekt | nein | Wie das Plugin nach dem Installieren eingestellt ist: `actionBar` (gleich in der Aktionsleiste, wenn dort Platz ist; nur mit Auslöser `action`), `automatic` („Automatisch beim Ablegen“; nur mit `automatic`), `replaceOriginal` („Original ersetzen“; nur mit `canReplaceOriginal`), je `true` oder `false`. Gilt nach „Installieren“ (Import) bzw. nach „Laden“ (Galerie), auch für Plugins mit `network`, `run` oder `tools`, denn das Plugin hat dann all seine Rechte. Danach ändert nur der Nutzer etwas; Updates fassen die Einstellungen nicht an. Die eigenen Einstellungen des Plugins (`settings`) haben ihren Standard in `default`, siehe 3.3. |

### 3.2 Texte in zwei Sprachen

Überall, wo „Text (3.2)“ steht, gibt es zwei Formen:

```json
"name": "Gilt für beide Sprachen"
"name": { "en": "English text", "de": "Deutscher Text" }
```

Regel: Ist die App auf Deutsch, gilt `de`, sonst `en`. Fehlt die gewünschte Sprache, gilt `en`. Fehlt auch `en`, gilt der alphabetisch erste vorhandene Eintrag. Andere Sprachschlüssel werden nicht verwendet.

### 3.3 settings

```json
"settings": [
  { "key": "format", "type": "choice", "title": { "en": "Format", "de": "Format" },
    "info": { "en": "Shown behind the (i)", "de": "Erscheint hinter dem (i)" },
    "default": "png",
    "options": [ { "value": "png", "title": "PNG" }, { "value": "jpg", "title": "JPEG" } ] },
  { "key": "keepName", "type": "toggle", "title": { "en": "Keep name", "de": "Namen behalten" }, "default": true },
  { "key": "prefix", "type": "text", "title": { "en": "Prefix", "de": "Präfix" }, "default": "" }
]
```

| Schlüssel | Pflicht | Bedeutung |
| --- | --- | --- |
| `key` | ja | Name des Werts in `bardrop.settings`. `replaceOriginal` ist reserviert. |
| `type` | ja | `toggle` (Schalter), `choice` (Auswahl), `text` (Textfeld). |
| `title` | ja | Text (3.2). |
| `info` | nein | Text (3.2), erscheint hinter einem (i). |
| `default` | nein | `toggle`: `true`/`false` (Standard `false`). `choice`: einer der `value` (Standard: die erste Möglichkeit). `text`: Text (Standard leer). |
| `options` | bei `choice` | Liste aus `{"value": "Text", "title": Text (3.2)}`. `value` ist **immer Text**, auch für Zahlen (`"1080"`, nicht `1080`). |

Darstellung wie die übrigen Einstellungen von BarDrop: Zwei Möglichkeiten und drei kurze Möglichkeiten erscheinen als Umschalter in der Zeile, sonst als Menü.

Im Skript: `bardrop.settings.<key>` liefert `true`/`false`, Texte als Text. `bardrop.settings.replaceOriginal` sagt, ob „Original ersetzen“ an ist.

### 3.4 icon

* `symbol`: Name eines **SF Symbols**, also eines der Systemsymbole, die auch Kurzbefehle verwendet und die auf jedem Mac vorhanden sind (z. B. `arrow.down.circle.fill`, `photo`, `link`, `doc.text`). Namen findet man in Apples App „SF Symbols“. Gibt es den Namen auf dem Mac nicht, zeigt BarDrop ein Puzzleteil.
* `color`: Farbe der Kachel als `#RRGGBB` (das `#` darf fehlen). Ungültig oder fehlend: grau.

BarDrop zeichnet das Symbol immer **weiß auf der farbigen Kachel mit leichtem Verlauf**, wie die Symbole der Einstellungen; im Rechtsklick in 16 pt, in der Aktionsleiste im Stil der Aktion „Teilen“. Eigene Bilddateien als Symbol gibt es nicht.

## 4. match: wofür ein Plugin zuständig ist

```json
"match": {
  "types": ["public.image", "com.adobe.pdf"],
  "extensions": ["txt", "md"],
  "links": { "hosts": ["example.com"], "patterns": ["^https://example\\.com/watch\\?"] }
}
```

Mindestens **eine** der vier Listen muss Einträge haben. Ein Objekt passt, wenn **irgendeine** Regel passt.

**Was BarDrop über ein Objekt weiß:**

| Objekt in der Ablage | `kind` | Typ | Endung |
| --- | --- | --- | --- |
| `.webloc`-Datei mit lesbarer Adresse (`URL` in der Property List) | `link` | `com.apple.web-internet-location` | `webloc` |
| Ordner (kein Paket) | `folder` | `public.folder` | die des Ordners, meist leer |
| alles andere, auch Pakete wie `.app` | `file` | aus der Endung, sonst aus der Datei | die Endung, klein geschrieben |

Links legt BarDrop selbst immer als `.webloc` ab.

**Regeln:**

* `extensions`: Vergleich ohne Groß- und Kleinschreibung; führende Punkte werden entfernt (`".PNG"` = `png`).
* `types`: Uniform Type Identifier. Ein Objekt passt auch, wenn sein Typ davon **abgeleitet** ist: `public.image` passt zu PNG, JPEG, HEIC usw., `public.movie` zu MP4 und MOV, `public.text` zu TXT, Markdown, Quelltext. Unbekannte Bezeichner werden übergangen.
* `links.hosts`: gilt **nur für Links**. `example.com` passt zu `example.com` und jeder Subdomain (`www.example.com`, `m.example.com`), aber nicht zu `notexample.com`. `*.example.com` bedeutet dasselbe wie `example.com`. `*` allein passt zu jedem Link mit `http` oder `https`; an anderer Stelle ist `*` nicht erlaubt. Nur die Domain angeben, ohne `https://`, ohne Pfad, ohne Port.
* `links.patterns`: gilt **nur für Links**. Reguläre Ausdrücke (ICU-Syntax von macOS), geprüft auf die ganze Adresse, **ohne** Groß- und Kleinschreibung; ein Treffer irgendwo genügt. Mit `^` am Anfang verankern. In JSON jeden `\` doppelt schreiben.
* Ein Link passt außerdem auf `extensions: ["webloc"]`.

**Links aus dem Browser:** Wird ein Link zusammen mit einem Vorschaubild gezogen (z. B. aus einer Webseite), übernimmt BarDrop normalerweise das Bild. Passt der Link aber zu `links` eines **eingeschalteten** Plugins, übernimmt BarDrop den Link als `.webloc`. Das gilt nur für `links.hosts` und `links.patterns` und nicht für Regeln, die jede Adresse annehmen (Domain `*` oder ein Muster, das auf jede Seite passt): Solche Plugins bekommen gezogene Links, ein Bild bleibt aber ein Bild.

## 5. Auslöser

**Rechtsklick (`menu`):** Passende, eingeschaltete Plugins erscheinen unter den gewohnten Einträgen, nach einer Trennlinie, mit ihrem Symbol und `actionTitle`. Bis zu drei direkt, ab vier gesammelt im Untermenü „Plugins“. Bei mehreren ausgewählten Objekten erscheint ein Plugin, wenn es zu mindestens einem passt; es läuft dann für jedes passende Objekt einmal, mit `batch` einmal mit allen.

**Aktionsleiste (`action`):** Einstellungen → Aktionen → „Aktion hinzufügen“ (oder `defaults.actionBar`, 3.1). Ist das Plugin aus, steht seine Aktion weder in der Ablage noch in Einstellungen → Aktionen und zählt nicht zur Grenze der Leiste; beim Einschalten kommt sie wieder ans Ende, wenn Platz ist. Darauf ziehen: läuft für die gezogenen Objekte; ein Klick führt es nicht aus. Passt nichts, gibt es einen Warnton.

**Automatisch beim Ablegen (`automatic`):** Je Plugin ein Schalter, standardmäßig aus (Ausnahme 3.1 `automaticByDefault`). Es zählt nur, was der Nutzer selbst in die Ablage legt: Ziehen und ⌘V. Nicht: Bildschirmfotos, Ergebnisse von Aktionen und Plugins, Widerrufen, die Einführung. Für jedes abgelegte Objekt läuft **höchstens ein** Plugin: das erste in der Reihenfolge unter Einstellungen → Plugins → Erweitert → „Reihenfolge beim Ablegen“, das eingeschaltet ist, automatisch läuft und passt. Dort ändert man die Reihenfolge per Ziehen (erscheint ab zwei automatischen Plugins). Oben in der Ablage, wo sonst die Anzahl steht, steht dann „Plugin läuft“.

Ein Plugin startet nur, wenn es **ohne Rückfrage** laufen kann: Zustimmung (`consent`) gegeben, alle Rechte aus `permissions` erteilt, alle Programme aus `tools` erlaubt. Fehlt etwas, fragt BarDrop all das **vor dem Start in einem Fenster** ab: beim Einschalten des Plugins, beim Einschalten von „Automatisch beim Ablegen“, bei Rechtsklick und Aktionsleiste und beim Ablegen (einmal je Ablegen). Lehnt man ab, läuft es nicht, und oben steht „Nicht gestartet“. Während eines automatischen Laufs fragt das Plugin nie.

**Gleichzeitig:** Höchstens drei Plugins laufen gleichzeitig, weitere warten in der Reihenfolge, in der sie gestartet wurden (ihr Platzhalter zeigt eine Uhr und „Wartet“). Dasselbe Plugin startet für dieselbe Datei nicht ein zweites Mal, solange es noch läuft; oben erscheint dann „Läuft schon“.

## 6. Rechte

| Recht | erlaubt | Zeile im Fenster |
| --- | --- | --- |
| `network` | `bardrop.fetch`, `bardrop.download` | „Zugriff aufs Internet“ |
| `run` | `bardrop.run`, also auch `tools` | „Programme ausführen“, als Warnung: vollen Zugriff auf den Mac |
| `clipboard` | `bardrop.setClipboard` | „Zwischenablage“ (gilt ohne Frage als erteilt, wie bei macOS) |

* Ein Aufruf ohne das Recht in `permissions` scheitert **sofort** mit dem Fehler `Permission “…” is missing in manifest.json`, ohne Frage.
* Erlaubt wird **alles auf einmal**: Zustimmung, Rechte und Programme stehen in einem Fenster („„…“ erlauben?“ mit einer Zeile je Recht und Programm, „Erlauben“ und „Abbrechen“). Es kommt beim Einschalten oder vor dem ersten Lauf, nie mitten im Lauf. „Abbrechen“ startet das Plugin nicht und fragt beim nächsten Mal erneut.
* Beim Import einer `.bdrop`-Datei stehen Rechte, Programme und Hinweis schon im Installieren-Fenster: „Installieren“ bzw. „Aktualisieren“ erteilt sie, danach kommt kein weiteres Fenster.
* Plugins aus der Galerie („Laden“, Standard-Plugins und automatische Aktualisierungen aus dem Katalog, je mit Prüfsumme geladen) bekommen Zustimmung, Rechte und Programme sofort, ohne Erlauben-Fenster.
* `clipboard` gilt immer als erteilt, sobald es in `permissions` steht (Text in die Zwischenablage legen fragt auch macOS nicht ab).
* Erteilte Rechte gelten für **genau diesen Code**: eine SHA-256-Prüfsumme über **alle Dateien** des Plugins (Pfad und Inhalt; nur `.DS_Store` zählt nicht), denn das Skript kann weitere Dateien lesen und als Code ausführen. Jede Änderung an irgendeiner Datei auf der Platte setzt alle Rechte zurück, und BarDrop fragt vor dem nächsten Lauf erneut. Aktualisierungen aus dem Katalog erteilen ohne Frage alles, was die neue Fassung angibt; ein Import erteilt die Rechte aus seiner Liste.
* Ein Plugin ohne Erlaubnis ist aus: Die Liste zeigt „Aus“, und Einschalten fragt erst in einem Fenster nach allem, was fehlt (etwa nachdem ein bearbeitetes Skript seine Rechte verloren hat). Info → „Zugriff“ auf der Seite des Plugins zeigt den Stand in einer Zeile („Erlaubt“ oder „Nicht erlaubt“) mit „Erlauben“ bzw. „Entziehen“, darunter Berechtigungen, Programme und Hinweis einzeln, je „Erlaubt“ oder „Nicht erlaubt“. „Entziehen“ nimmt Rechte, Programme und Zustimmung zurück und schaltet das Plugin damit aus. Plugins aus der Galerie brauchen keine Erlaubnis: Fehlt sie, lädt BarDrop beim nächsten Abgleich die geprüfte Fassung neu.
* Es gibt **keine Sandbox von macOS** um Plugins. Das Skript selbst kann ohne Rechte nur die Aufrufe aus 9 nutzen. Ein mit `run` gestartetes Programm hat aber die vollen Rechte des Benutzers.

## 7. tools: nachgeladene Programme

BarDrop liefert nie Programme Dritter mit. Ein Plugin kann Programme nennen, die BarDrop beim ersten Gebrauch lädt (erlaubt wird das Laden zusammen mit den Rechten, siehe 6):

```json
"tools": [
  { "id": "mytool", "name": "My Tool",
    "url": "https://example.com/releases/1.0/mytool_macos",
    "sha256": "64 Hex-Zeichen",
    "license": "MIT", "homepage": "https://example.com" }
]
```

| Schlüssel | Pflicht | Bedeutung |
| --- | --- | --- |
| `id` | ja | Name, unter dem das Skript es startet: `bardrop.run("mytool", […])`. Plugins teilen sich ein Programm, wenn die Download-Adresse gleich ist (siehe unten). |
| `name` | ja | Anzeige im Erlauben-Fenster. |
| `url` | ja | `https://`, zeigt auf **eine einzelne ausführbare Datei** für macOS. Archive (ZIP, DMG, PKG) werden **nicht** entpackt. Umleitungen werden befolgt. |
| `sha256` | eins von beiden | Prüfsumme der Datei. |
| `checksums` | eins von beiden | `https://`-Adresse einer Prüfsummenliste des Herausgebers. Gesucht wird die Zeile `<64 Hex-Zeichen> <Dateiname>` oder `<…> *<Dateiname>`; Dateiname ist der letzte Teil von `url`. Für Adressen auf „latest“. |
| `license` | nein | Erscheint im Erlauben-Fenster. |
| `homepage` | nein | Wird gespeichert. |
| `refreshDays` | nein | Nach so vielen Tagen lädt BarDrop die Datei beim nächsten Gebrauch neu, ohne erneut zu fragen. Ohne Angabe nie. |
| `archive` | nein | `"zip"`: `url` liefert ein ZIP-Archiv. BarDrop prüft die Prüfsumme **des Archivs**, entpackt es und übernimmt nur die Datei `executable`. Andere Archivarten gibt es nicht. |
| `executable` | mit `archive` | Pfad des Programms im Archiv, z. B. `"tool"` oder `"bin/tool"`, ohne `/` am Anfang und ohne `..`. |

`{arch}` in `url` und `checksums` wird zur Architektur des Mac: `aarch64` (Apple Chip) oder `x86_64` (Intel). Damit gibt es je Mac eine andere Datei, also `checksums` statt `sha256`. `id` darf nur Buchstaben, Ziffern, `.`, `-` und `_` enthalten; die Datei wird **unter diesem Namen** gespeichert, andere Programme finden sie also über diesen Namen (z. B. `id: "tool"`).

Beispiel für ein Programm im Archiv:

```json
{ "id": "tool", "name": "Tool",
  "url": "https://example.com/downloads/tool-{arch}.zip",
  "checksums": "https://example.com/downloads/tool-{arch}.zip.sha256",
  "archive": "zip", "executable": "tool", "license": "MIT", "refreshDays": 30 }
```

Ablauf: Fehlt die Datei, fragt BarDrop („… laden?“ mit Herkunft und Lizenz). Fehlen beim Einschalten von „Automatisch beim Ablegen“ oder beim Ablegen mehrere Dinge (Zustimmung, Rechte, Programme), fragt BarDrop alles in **einem** Fenster. Nach „Laden“ wird geladen (der Platzhalter zeigt „Lädt …“ mit Prozent), die Prüfsumme verglichen (passt sie nicht, wird die Datei gelöscht und der Aufruf scheitert), die Datei ausführbar gemacht (755) und die Quarantäne entfernt. Ablage: `~/Library/Application Support/BarDrop/Tools/<id>-<Kennung der Adresse>/<id>` mit `meta.json` daneben; zwei Plugins mit derselben `id`, aber verschiedenen Adressen überschreiben sich also nicht. Die Erlaubnis wird je Plugin **für genau diese Adresse** gespeichert und gilt danach auch für automatische Läufe. Ändert ein Update die Adresse, fragt BarDrop erneut; eine Aktualisierung aus dem Katalog erlaubt die neue Adresse sofort. Ohne Frage neu geladen wird nur ein veraltetes Programm von derselben Adresse (`refreshDays`, neue Prüfsumme). Laden zwei Läufe gleichzeitig, lädt nur einer, der andere wartet. Hat ein anderes Plugin dieselbe Datei schon geladen (gleiche Adresse, mit `sha256` auch gleiche Prüfsumme, noch innerhalb von `refreshDays`), wird sie mitbenutzt, auch unter anderer `id`: Es wird nichts geladen, gefragt wird für dieses Plugin trotzdem einmal (außer es stammt aus der Galerie). Einstellungen → Plugins → Plugin → Info → Programme → „Aktualisieren“ lädt die erlaubten Programme des Plugins ohne Frage neu, etwa wenn eine neuere Fassung des Programms einen Fehler behebt. Beim Entfernen eines Plugins bleiben geladene Programme liegen.

## 8. Ergebnis

* `run(item)` endet ohne Fehler (auch ein `async`-`run`, dessen Versprechen erfüllt wird): **Erfolg**. Der Rückgabewert wird nicht verwendet.
* Wirft `run` einen Fehler oder wird das Versprechen abgelehnt: **Fehlschlag**. Es kommt nichts in die Ablage. BarDrop zeigt **kein Fenster**: Der Platzhalter rüttelt kurz, oben steht „Fehlgeschlagen“, und die Meldung steht in den Einstellungen unter „Letzter Fehler“ und im Protokoll: `error.message`, bei Fehlern im Code (`TypeError`, `ReferenceError`, `SyntaxError` …) mit dem Typ davor und Datei und Zeile dahinter (`TypeError: … (main.js:12)`); eine eigene Meldung mit `throw new Error(…)` erscheint genau so, wie sie ist; ein Tipp für den Nutzer gehört in `hint` (`throw { message: "…", hint: "Installiere … und versuch es noch einmal." }` oder `error.hint = "…"` an einem `Error`), höchstens 300 Zeichen, er steht unter der Meldung und in einer eigenen Zeile im Protokoll, also nicht an die Meldung anhängen. „Letzter Fehler“ bleibt bis zum Beenden.
* Bei Erfolg werden alle **Einträge der obersten Ebene** im Ausgabeordner übernommen, alphabetisch sortiert, **Ordner eingeschlossen**. Ausgenommen sind Namen, die mit `.` beginnen, und die Endungen `part`, `ytdl`, `tmp`, `download`, `crdownload`. Ist der Ordner leer, verschwindet nur der Platzhalter.
* Die Dateien werden in den Speicher von BarDrop verschoben und **direkt hinter dem Original** eingefügt (in der Reihenfolge, die der Nutzer sieht; liegt das Original in einem Stapel, hinter ihm im Stapel). Sie erscheinen sofort mit Vorschau und sind danach ausgewählt. Liegt das Original nicht mehr in der Ablage, kommen sie dazu wie neu abgelegte Objekte.
* „Original ersetzen“ (nur mit `canReplaceOriginal`, Schalter des Nutzers, beim Start des Laufs festgelegt): Solange das Plugin läuft, steht sein Platzhalter **an der Stelle des Originals**, das Original selbst ist nicht zu sehen. Danach steht das Ergebnis genau dort, ohne Überblenden; das Original ist **aus der Ablage** genommen, nie gelöscht, ⌘Z holt es zurück. Scheitert der Lauf oder wird er abgebrochen, ist das Original wieder zu sehen.

**Platzhalter:** Während ein Plugin läuft (ab 0,3 s nach dem Start, damit ein Lauf, der sofort fertig ist, nicht aufblitzt), steht neben dem Original (bei „Original ersetzen“ an seiner Stelle) eine Vorschau mit dem Namen des Plugins darunter (oder dem `label` aus `bardrop.progress`). Sie ist erst durchsichtig und wird mit dem Fortschritt deckend; ein schmaler Balken zwischen Bild und Namen füllt sich mit `bardrop.progress`. Ohne Fortschritt wird das Bild sanft deckender und wieder durchsichtiger, und im Balken wandert ein kurzer Lichtstreifen. Gezeigt wird zuerst die Datei, an der das Plugin arbeitet. Sobald im Ausgabeordner eine Datei auftaucht, zeigt der Platzhalter das Symbol ihrer Art (auch während sie noch geschrieben wird; `film.mp4.part` gilt als Video), und sobald sie fertig ist (nicht versteckt, keine der Endungen oben, nicht leer, zweimal hintereinander gleich groß, geprüft zweimal pro Sekunde), ihr Vorschaubild: So sieht man das Ergebnis schon, bevor das Plugin fertig ist. Scheitert der Lauf, rüttelt der Platzhalter kurz, und sein Balken wird rot, bevor er verschwindet. Solange Plugins arbeiten, steht oben rechts im Kopf der Ablage „Plugin läuft“, bei mehreren „2 Plugins laufen“. Platzhalter lassen sich auswählen wie andere Objekte (Klick, ⌘- bzw. ⇧-Klick, Auswahlrahmen, Pfeiltasten); `⌫` bricht die ausgewählten ab. Fährt der Zeiger über den Platzhalter, hält ein Klick auf das Zeichen in der Mitte an bzw. setzt fort, das x oben rechts bricht ab. Rechtsklick: Fortschritt in Prozent (läuft im offenen Menü mit), „Anhalten“ bzw. „Fortsetzen“, „Abbrechen“. Wartet ein Plugin noch, gibt es nur „Abbrechen“.

* **Anhalten:** gestartete Programme und alle Programme, die diese selbst gestartet haben, bekommen `SIGSTOP`, Downloads pausieren. Das Skript selbst und `bardrop.sleep` laufen weiter.
* **Abbrechen:** wirkt sofort: Der Platzhalter verschwindet und der Platz für das nächste Plugin wird frei. Gestartete Programme und ihre Unterprogramme bekommen `SIGTERM`, wer nach 3 s noch läuft, `SIGKILL`. Anfragen werden abgebrochen, das Ergebnis wird verworfen. Der Arbeitsordner wird erst gelöscht, wenn alle Programme beendet sind. Programme, die das Skript ohne `await` gestartet hat, werden genauso beendet; nach dem Ende startet keines mehr.
* **Ausschalten oder Entfernen** eines Plugins bricht seine laufenden und wartenden Aufträge ab, ebenso das Ausschalten aller Plugins.
* Beim Beenden von BarDrop werden laufende Plugins abgebrochen.

## 9. Das Skript

### 9.1 Umgebung

* JavaScriptCore von macOS, also die Sprache JavaScript mit `async`/`await`, `Promise`, `JSON`, `RegExp`, `Map`, `Set` usw.
* **Zusätzlich vorhanden, von BarDrop bereitgestellt:** `URL` und `URLSearchParams` (wie im Browser), `setTimeout`, `setInterval`, `clearTimeout`, `clearInterval`, `queueMicrotask`, `TextEncoder`/`TextDecoder` (nur UTF-8), `atob`/`btoa`. Ein Fehler in einem Zeitgeber lässt den Lauf scheitern.
* **Nicht vorhanden:** DOM, `window`, globales `fetch` (statt dessen `bardrop.fetch`), `XMLHttpRequest`, `require`, `import`, Node-Module, `structuredClone`, Dateizugriff außer über `bardrop`.
* `console.log`, `console.info`, `console.warn`, `console.error` gibt es; sie schreiben wie `bardrop.log` ins Plugin-Protokoll. `console` nicht mit `let`/`const` neu anlegen.
* Jeder Lauf hat einen **eigenen, frischen Kontext**: Globale Variablen überleben keinen Lauf. Dauerhaftes gibt es nur über `settings`.
* Das Skript wird zuerst einmal ganz ausgeführt (globale Definitionen), dann wird `run(item, items)` aufgerufen. `items` ist die Liste aller Objekte des Laufs: mit `batch` alle, sonst nur `item`. `function run(item)` funktioniert weiter.
* Ein Fehler beim ersten Ausführen (z. B. Syntaxfehler) ist ein Fehlschlag. Fehlt `run`, ebenfalls („Im Skript fehlt die Funktion run“).
* Lange Rechnungen laufen, solange sie brauchen. Ist ein Lauf zu Ende („Abbrechen“, „Beenden“ unter Einstellungen → Plugins, Plugin ausgeschaltet), beendet BarDrop auch ein Skript, das noch rechnet, selbst in einer Endlosschleife, innerhalb etwa einer Viertelsekunde. Solange ein Plugin Läufe hat, steht in der Liste unter Einstellungen → Plugins „Läuft gerade“; die Seite des Plugins hat oben „Beenden“.
* Das Skript wird als **normales Skript** geladen, nicht als Modul: kein `import`/`export`, kein `await` und kein `return` außerhalb von Funktionen. `function run`, `var run =`, `let run =` und `const run =` funktionieren alle.

### 9.2 item

| Feld | Typ | Inhalt |
| --- | --- | --- |
| `kind` | Text | `"file"`, `"folder"` oder `"link"` |
| `path` | Text | Pfad der Datei in der Ablage (bei Links die `.webloc`) |
| `name` | Text | Dateiname mit Endung; bei Links der Name ohne `.webloc` |
| `extension` | Text | Endung, klein geschrieben, ohne Punkt |
| `type` | Text | Uniform Type Identifier, `""` wenn unbekannt |
| `url` | Text | nur bei Links: die Adresse |
| `size` | Zahl | Größe in Byte, nicht bei Ordnern |

Jeder Eintrag in `items` hat dieselben Felder.

### 9.3 bardrop

Alle Aufrufe mit `await` liefern ein Versprechen.

| Aufruf | Recht | Ergebnis und Regeln |
| --- | --- | --- |
| `bardrop.outputDirectory` | | Pfad des Ausgabeordners (Text). Dort liegt am Ende das Ergebnis. |
| `bardrop.pluginDirectory` | | Pfad des eigenen Plugin-Ordners (Text), mit `manifest.json`, Skript und weiteren Dateien. Für `bardrop.readFile(bardrop.pluginDirectory + "/vorlage.txt")`. |
| `bardrop.writeFile(name, text)` | | Schreibt `text` als UTF-8 in den Ausgabeordner (andere Werte werden wie mit `String()` zu Text, Objekte also zu `[object Object]`: vorher `JSON.stringify` verwenden). `name` muss Text sein, `text` darf nicht `undefined` oder `null` sein, sonst Fehler. Liefert den Pfad. Der Name wird bereinigt (siehe 9.4); gibt es ihn schon, heißt die Datei `Name 2.txt` usw. |
| `bardrop.createLink(url, title)` | | Legt `<title>.webloc` im Ausgabeordner an (ohne `title`: die Domain). Nur `http`- und `https`-Adressen. Liefert den Pfad. Ungültige Adresse: Fehler. |
| `bardrop.readFile(path)` | | Liest eine Datei als Text (UTF-8, ungültige Bytes werden ersetzt), höchstens 20 MB. Ein Pfad ohne `/` am Anfang gilt relativ zum Ausgabeordner; eigene Dateien also mit `bardrop.pluginDirectory`. Erlaubt nur: die Pfade von `item` und `items`, Dateien im Ausgabeordner, Dateien im eigenen Plugin-Ordner. Sonst Fehler. Für Binärdaten `bardrop.readData`. |
| `bardrop.readData(path)` | | Wie `readFile`, mit denselben Regeln und derselben Grenze, liefert die Bytes aber als `Uint8Array`. |
| `bardrop.writeData(name, data)` | | Wie `writeFile`, schreibt aber Bytes unverändert: `data` ist ein `Uint8Array` (oder ein anderes typisiertes Array), ein `ArrayBuffer`, eine Liste von Zahlen 0 bis 255 oder Base64-Text. Sonst Fehler. Liefert den Pfad. |
| `bardrop.progress(anteil, label)` | | `anteil` 0 bis 1 (wird begrenzt); keine Zahl (z. B. `null`) heißt „ohne Fortschritt“. `label` optional, höchstens 60 Zeichen, ersetzt den Namen unter dem Platzhalter. Die Anzeige erneuert sich höchstens alle 100 ms. |
| `bardrop.notify(text)` | | Kurze Meldung oben in der Ablage, etwa 2 Sekunden. Höchstens 40 Zeichen; die Zeile ist schmal, voll zu sehen sind bei Standardgröße etwa 20. |
| `bardrop.isCancelled()` | | `true`, wenn der Nutzer abgebrochen hat. In langen Schleifen abfragen. |
| `await bardrop.sleep(ms)` | | Wartet `ms` Millisekunden (0 bis 3 600 000). |
| `bardrop.findProgram(name)` | | Pfad eines Programms oder `null`. Sucht an denselben Orten wie `bardrop.run` (siehe dort), auch in Programmen, die andere Plugins geladen haben; ein Programm aus den eigenen `tools` nur, wenn es schon geladen ist. Lädt nichts, startet nichts, braucht kein Recht. Statt `which` zu starten. |
| `bardrop.log(text)` | | Zeile im Plugin-Protokoll (nur wenn es eingeschaltet ist, siehe 14), höchstens 300 Zeichen. |
| `await bardrop.fetch(url, options)` | `network` | `options` optional: `method` (Text), `headers` (Objekt), `body` (Text). Nur `http`/`https`, 60 s Zeitlimit, Kennung `BarDrop/<Version>`. Liefert `{status, url, headers, text}`; `headers` mit klein geschriebenen Namen, `text` höchstens 20 MB. Abgelehnt wird nur bei Netzwerkfehlern, **nicht** bei Status 404 oder 500: `status` selbst prüfen. |
| `await bardrop.download(url, options)` | `network` | Lädt in den Ausgabeordner, mit Fortschritt am Platzhalter. `options` optional: `name`, `method`, `headers`. Dateiname: `name`, sonst der vom Server vorgeschlagene, sonst der letzte Teil der Adresse (bereinigt, 9.4). Liefert den Pfad. Abgelehnt bei Netzwerkfehler oder Status außerhalb 200 bis 299. |
| `await bardrop.run(befehl, argumente, options)` | `run` | Startet ein Programm und wartet, bis es endet. `befehl`: eine `id` aus `tools`, ein absoluter Pfad oder ein Name, gesucht in den eigenen Programmen des Plugins, dann in `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/opt/homebrew/bin`, `/usr/local/bin`, dann in den Programmordnern im Benutzerordner (`~/.<name>/bin`, `~/.local/bin`, dorthin installieren viele Laufzeiten ohne Homebrew) und zuletzt in den Programmen, die andere Plugins schon geladen haben. Vorher prüfen mit `bardrop.findProgram`. `argumente`: Liste, jedes Element wird zu Text; es gibt **keine Shell** (keine Platzhalter, keine Umleitungen; dafür `"/bin/sh", ["-c", "…"]`). Arbeitsordner ist der Ausgabeordner. Umgebung: die von BarDrop, dazu `PATH` = die Suchorte oben in derselben Reihenfolge (so findet ein Programm, das selbst nach einem anderen sucht, etwa `which`, dasselbe), `BARDROP_OUTPUT` = Ausgabeordner. Keine Eingabe (stdin leer). `options.onOutput(zeile)` wird für jede Zeile von stdout und stderr aufgerufen, beide getrennt zerlegt; Zeilen enden an `\n` **und** `\r`, leere Zeilen fallen weg, Zeilen über 64 KB werden geteilt. Alle Zeilen kommen an, bevor `run` sein Ergebnis liefert. Ein Fehler in `onOutput` beendet den ganzen Lauf mit diesem Fehler. Liefert `{code, stdout, stderr}` (je höchstens 1 MB). Ein Code ungleich 0 wird **nicht** abgelehnt: `code` selbst prüfen. Abgelehnt wird, wenn das Programm nicht gefunden wird, nicht starten kann, das Recht fehlt oder abgebrochen wurde. |
| `bardrop.setClipboard(text)` | `clipboard` | Legt Text in die Zwischenablage. |
| `bardrop.settings` | | Werte der Einstellungen (3.3) und `replaceOriginal`. |
| `bardrop.language` | | `"de"` oder `"en"`, wie die App. |
| `bardrop.appVersion` | | z. B. `"1.31.0-beta.2"`. |
| `bardrop.plugin` | | `{id, version}`. |

### 9.4 Dateinamen

Für `writeFile`, `writeData`, `createLink` und `download` gilt: nur der letzte Teil eines Pfads zählt; `/` und `:` werden zu `-`, Zeilenumbrüche zu Leerzeichen; Leerzeichen am Rand fallen weg; führende Punkte werden entfernt; höchstens 80 Zeichen (längere Namen werden vor der Endung gekürzt, `.txt` oder `.webloc` bleibt); leer wird zu „Item“ bzw. „Objekt“. Programme, die selbst in den Ausgabeordner schreiben, sind davon nicht betroffen.

## 10. Katalog (Galerie)

Der Katalog liegt auf dem eigenen Zweig **`plugin-katalog`** dieses Repositorys: `https://raw.githubusercontent.com/zzuuuiii/BarDrop/plugin-katalog/index.json`, die Plugins daneben unter `plugins/<id>/<id>-<version>.bdrop`. Die Galerie wird nicht von Hand bearbeitet. BarDrop bis Beta 7 liest noch den leeren `Plugins/index.json` auf `main`; er bleibt unverändert.

**Eintragen über `Plugins/`** (einfachster Weg, nur im Browser): die `.bdrop`-Datei auf GitHub in den Ordner `Plugins/` auf `main` hochladen (Add file → Upload files, Commit). Der Workflow `plugin-gallery.yml` (`scripts/build_gallery.py`) übernimmt sie in etwa einer Minute nach `plugin-katalog`; ein Push, der nur `Plugins/` ändert, baut kein Release der App.

* Jede `.bdrop` in `Plugins/` (auch in Unterordnern) wird wie mit `check_plugin.py` geprüft. Fehlerhafte werden übersprungen und im Lauf als Fehler gemeldet; der Lauf schlägt dann fehl, die übrigen werden trotzdem eingetragen.
* Die Datei wird unverändert übernommen. Liegt dieselbe `id` mehrfach dort, gilt die höchste `version`.
* Aktualisieren: neue Datei mit höherer `version` hochladen. `updated` ändert sich nur, wenn sich die Prüfsumme ändert.
* Entfernen: Datei löschen. Der Eintrag bleibt mit `removed: true` stehen.
* `category` kommt aus einem freiwilligen Schlüssel `category` der manifest.json (BarDrop selbst ignoriert ihn), `standard` wird nur im Katalog gesetzt; beides bleibt bei Aktualisierungen erhalten.
* Welche ids aus `Plugins/` stammen, steht in `from-main.json` auf `plugin-katalog`. Einträge, die mit `publish_plugin.py` entstanden sind, lässt der Workflow unverändert.

**Eintragen mit dem Skript** (Kommandozeile, Alternative):

```sh
python3 scripts/publish_plugin.py MeinPlugin/ --category images          # prüfen, packen, eintragen
python3 scripts/publish_plugin.py MeinPlugin/ --push                     # … und hochladen
python3 scripts/publish_plugin.py MeinPlugin/ --standard                 # für alle automatisch
python3 scripts/publish_plugin.py --remove io.github.name.plugin --push  # zurückziehen
```

Das Skript prüft wie `check_plugin.py` (bei Fehlern bricht es ab), verlangt eine höhere `version` als im Katalog, packt das Plugin, entfernt ältere Fassungen, rechnet die Prüfsumme und schreibt den Eintrag. Der Katalog liegt dabei als Arbeitsordner `.katalog/` neben dem Projekt (Git-Worktree, beim ersten Mal angelegt, steht in `.gitignore`).

```json
{
  "schema": 1,
  "plugins": [
    { "id": "io.github.name.plugin", "version": "1.0.0",
      "name": { "en": "Name", "de": "Name" },
      "description": { "en": "…", "de": "…" },
      "icon": { "symbol": "link", "color": "#34C759" },
      "url": "https://raw.githubusercontent.com/zzuuuiii/BarDrop/plugin-katalog/plugins/io.github.name.plugin/io.github.name.plugin-1.0.0.bdrop",
      "sha256": "Prüfsumme der .bdrop", "size": 4812, "toolsSize": 61200000,
      "category": "links", "author": "Name", "homepage": "https://…",
      "permissions": ["network"], "tools": ["mytool"], "updated": "2026-10-22",
      "standard": false, "removed": false, "minAppVersion": "1.31.0" }
  ]
}
```

| Schlüssel | Bedeutung |
| --- | --- |
| `id`, `version`, `name`, `url`, `sha256` | Pflicht. `id` muss der `id` im Manifest entsprechen, die Prüfsumme der Datei genau stimmen, sonst wird nichts installiert. |
| `description`, `icon`, `author`, `homepage`, `minAppVersion` | aus dem Manifest |
| `category` | freiwillig: `images`, `links`, `documents`, `text`, `media`, `files` oder `other` (für später; die Galerie gruppiert noch nicht danach) |
| `permissions`, `tools` | aus dem Manifest. Die Galerie zeigt daraus vor dem Laden „Offline“, „Programm“ (lädt einmal ein Programm, danach offline) oder „Internet“, jeweils mit Zeichen. Fehlt `permissions`, zeigt sie dazu nichts. |
| `size` | Größe der `.bdrop` in Bytes |
| `toolsSize` | Größe der Programme aus `tools`, wie sie auf dem Mac liegen (das Skript fragt sie bei den Adressen an, bei ZIP-Archiven die ausgepackte Datei). Die Galerie zeigt beides getrennt: „8 KB + 61 MB“. |
| `updated` | Datum dieser Version |
| `downloads` | wie oft das Plugin geladen wurde, alle Versionen zusammen (GitHub zählt an den Dateien des Releases `plugin-galerie`, `scripts/gallery_downloads.py` trägt es täglich ein); die fünf meistgeladenen stehen auf der Startseite |
| `added` | Datum, seit dem das Plugin in der Galerie steht; bleibt bei neuen Versionen gleich (zwei Monate als neu gezeigt) |
| `standard`, `removed` | siehe unten |

* Abfrage alle drei Stunden, nur bei eingeschalteten Plugins; beim Einschalten sofort; beim Öffnen von Einstellungen → Plugins, wenn die letzte Abfrage über eine Minute her ist. Neue Versionen werden von selbst installiert. Der zuletzt geladene Katalog steht gleich nach dem Start bereit. Ein Plugin gilt zwei Monate nach `added` (sonst `updated`) als neu.
* `standard: true`: wird automatisch installiert (ausgeschaltet), still aktualisiert, sobald `version` höher ist, lässt sich weder bearbeiten noch entfernen. Ohne Internet erscheint es als „Noch nicht geladen“ mit „Erneut versuchen“.
* Ist noch kein Plugin installiert, zeigt Einstellungen → Plugins gleich die verfügbaren unter „Verfügbar“. Sonst führt „Weitere Plugins“ (rechts die Zahl der neuen) dorthin; die Liste zeigt alle noch nicht installierten Einträge (ab sieben mit Suche), je mit Name, „Offline“, „Offline nach dem Einrichten“ (lädt einmal ein Programm) oder „Nutzt das Internet“ und der Größe, dazu „Laden“; die Beschreibung steht beim Darüberfahren. Nach „Laden“ bekommt das Plugin sofort all seine Rechte, ohne Erlauben-Fenster (siehe 6); danach ist es an, nach `defaults` eingestellt, und seine Seite öffnet sich.
* `removed: true`: Standard-Plugins werden beim nächsten Abgleich entfernt; andere verschwinden aus der Galerie, bleiben aber installiert.
* Einträge mit einer `minAppVersion`, die neuer ist als BarDrop, werden übergangen.
* Einstellungen → Plugins ist wie die Systemeinstellungen aufgebaut: In der Liste stehen eingeschaltete Plugins zuerst, je mit Name, Version und Größe (oder was ansteht) und „Ein“ bzw. „Aus“; ein Klick öffnet seine Seite, oben in der Titelzeile führt ‹ (oder Esc) zurück, ein erneuter Klick auf „Plugins“ in der Seitenleiste zur Startseite. Die Seite zeigt oben eine Karte mit Symbol, Name, Beschreibung und Schalter; darunter in derselben Karte, falls nötig, „Läuft“ (mit „Beenden“) und „Letzter Lauf fehlgeschlagen“ (mit „Fehler kopieren“; der Text steht beim Darüberfahren). Dann „Verhalten“ (Beim Ablegen, Original ersetzen; Erklärungen im Info-Knopf), die Einstellungen des Plugins und die Info: Internet („Nein“, „Einmal, für Programme“ oder „Ja“), Passt zu, Programme (Größe, „Aktualisieren“ lädt ihre neueste Version) und Zugriff; Version, Entwickler und Größe stehen als graue Zeile darunter. Unter der Liste „Galerie“ mit den fünf meistgeladenen Plugins zum Laden und darunter „Weitere Plugins“ (rechts die Zahl der Plugins, die höchstens zwei Monate neu sind; in der Galerie tragen sie „NEU“). Ein geladenes Plugin steht danach unter „Installiert“, und seine Seite öffnet sich. Ohne installierte Plugins fehlt nur „Installiert“. Ganz unten die Karte „Erweitert“: „Aus Datei installieren“ mit „Importieren“ und, eingeklappt unter „Fehlersuche“, der Schalter „Plugin-Protokoll“ (siehe 14, an: zusätzlich „Protokoll sichern“). Ein entferntes Galerie-Plugin steht sofort wieder unter „Galerie“.
* Einreichen per Pull Request mit der `.bdrop` in `Plugins/` auf `main`; jedes Plugin wird vor dem Aufnehmen geprüft. Alles in `Plugins/` ist öffentlich.

## 11. Prüfen vor dem Weitergeben

```sh
python3 scripts/check_plugin.py MeinPlugin/          # Ordner prüfen
python3 scripts/check_plugin.py MeinPlugin/ --pack   # prüfen und .bdrop erzeugen
python3 scripts/check_plugin.py MeinPlugin.bdrop     # fertige Datei prüfen
```

Das Programm prüft jede Regel aus 2 bis 7, warnt vor Aufrufen, die es in JavaScriptCore nicht gibt, vergleicht genutzte Aufrufe mit `permissions` und prüft mit Node.js (falls installiert) die Syntax, und zwar wie BarDrop als normales Skript. Link-Muster prüft es nach den Regeln von macOS (ICU): `(?<name>…)` geht, Pythons `(?P<name>…)` und `{,3}` nicht. Mit `--pack` bleiben versteckte Dateien und Ordner (`.git`, `.DS_Store`) draußen.

**Danach von Hand:**

1. In BarDrop importieren, Plugin einschalten.
2. Per Rechtsklick an einem passenden Objekt ausprobieren; erscheint es nicht, passt `match` nicht.
3. Fehler stehen unter Einstellungen → Plugins → Plugin → „Letzter Fehler“ und im Protokoll.
4. Mehr Einzelheiten: Einstellungen → Plugins → Erweitert → Fehlersuche → „Plugin-Protokoll“, dann `bardrop.log`/`console.log` im Skript (Abschnitt 14).
5. Erst dann „Automatisch beim Ablegen“ ausprobieren.

## 12. Häufige Fehler

| Fehler | Folge | Richtig |
| --- | --- | --- |
| `"version": 1.0` (Zahl) | Manifest unlesbar | `"version": "1.0"` |
| `"value": 1080` in `options` | Manifest unlesbar | `"value": "1080"` |
| unbekanntes Recht, z. B. `"files"` | Plugin abgelehnt | nur `network`, `run`, `clipboard` |
| `bardrop.run` ohne `"run"` | Fehler beim Aufruf | Recht eintragen |
| `tools` ohne `"run"` | Programm nicht startbar | `"permissions": ["run"]` |
| `"hosts": ["https://example.com"]` | passt nie | `"hosts": ["example.com"]` |
| `"patterns": ["\.pdf$"]` | ungültiges JSON | `"\\.pdf$"` |
| `extensions` für Links | passt nur auf `webloc` | `links.hosts` oder `links.patterns` |
| globales `fetch` | Fehler im Skript | `bardrop.fetch` |
| `which` starten, um ein Programm zu finden | findet nicht alles | `bardrop.findProgram` |
| Tipp an die Fehlermeldung gehängt | steht als ein Block unter „Letzter Fehler“ | `throw { message, hint }` |
| `fetch` ohne `status`-Prüfung | Fehlerseite als Ergebnis | `if (r.status !== 200) throw new Error(…)` |
| `run` ohne `code`-Prüfung | Fehlschlag bleibt unbemerkt | `if (r.code !== 0) throw new Error(r.stderr)` |
| Ergebnis außerhalb des Ausgabeordners | erscheint nicht | immer in `bardrop.outputDirectory` schreiben |
| Zwischendateien im Ausgabeordner | erscheinen als Objekte | löschen oder mit `.` am Anfang benennen |
| Archiv als `tools.url` | nicht ausführbar | einzelne ausführbare Datei |
| `automaticByDefault` mit `network` | wirkt nicht | `defaults.automatic` (gilt nach dem Erlauben) |
| Skript bearbeitet | alle Rechte weg | erwartet; erneut erlauben |

## 13. Beispiel: Tracking aus Links entfernen

`manifest.json`:

```json
{
  "schema": 1,
  "id": "io.github.name.clean-link",
  "name": { "en": "Clean Link", "de": "Link bereinigen" },
  "description": { "en": "Removes tracking from links", "de": "Entfernt Tracking aus Links" },
  "version": "1.0.0",
  "icon": { "symbol": "link", "color": "#34C759" },
  "minAppVersion": "1.31.0",
  "match": { "links": { "hosts": ["*"] } },
  "triggers": ["menu", "automatic"],
  "automaticByDefault": false,
  "canReplaceOriginal": true
}
```

`main.js`:

```js
function run(item) {
  if (item.kind !== "link") return;
  var hashAt = item.url.indexOf("#");
  var hash = hashAt >= 0 ? item.url.slice(hashAt) : "";
  var rest = hashAt >= 0 ? item.url.slice(0, hashAt) : item.url;
  var queryAt = rest.indexOf("?");
  if (queryAt < 0) return;                       // nichts zu tun: kein Ergebnis
  var keep = rest.slice(queryAt + 1).split("&").filter(function (pair) {
    return pair && !/^(utm_|fbclid=|gclid=|mc_)/.test(pair);
  });
  var clean = rest.slice(0, queryAt) + (keep.length ? "?" + keep.join("&") : "") + hash;
  bardrop.createLink(clean, item.name);
}
```

## 14. Plugin-Protokoll

Einstellungen → Plugins → Erweitert → Fehlersuche → „Plugin-Protokoll“ (standardmäßig aus; an: zusätzlich „Protokoll sichern“), aufgebaut wie das Diagnoseprotokoll: Beim Einschalten erklärt ein Hinweis, was erfasst wird; „Protokoll sichern“ speichert es als Textdatei, wohin man will; Ausschalten löscht es. Die Datei liegt unter `~/Library/Logs/BarDrop/Plugins.log` (ab 2 MB wird sie zu `Plugins-alt.log`; „Protokoll sichern“ nimmt beide).

Es ist **getrennt vom Diagnoseprotokoll** von BarDrop: eigene Datei, eigener Schalter, in allen Versionen verfügbar. Plugin-Ereignisse stehen nur hier, nicht im Diagnoseprotokoll. Anders als dieses nennt es Dateinamen, Adressen und Fehlermeldungen. Es bleibt auf dem Mac.

Jede Zeile: Zeit, Plugin (oder Programm), Art, Text. Arten:

| Art | Wann |
| --- | --- |
| `start` | Lauf beginnt: Version, von Hand oder automatisch, ob es das Original ersetzt, Objekt |
| `ok` | Lauf fertig, mit den Namen der Ergebnisse |
| `fehler` | Lauf gescheitert, mit der Meldung; auch wenn ein automatischer Lauf nicht starten konnte |
| `abbruch` | vom Nutzer abgebrochen |
| `recht` | Recht erlaubt, nicht erlaubt oder fehlend bei einem automatischen Lauf |
| `programm` | Programm gestartet (mit Argumenten), beendet (Code, Dauer, letzte Zeilen von stderr), geladen, von einem anderen Plugin mitbenutzt, aktualisiert, Prüfsumme falsch; `findProgram` mit Ergebnis |
| `hinweis` | der `hint` eines gescheiterten Laufs |
| `netz` | `fetch` und `download`: Domain und Status oder Fehler |
| `skript` | `bardrop.log` und `console.log` |
| `install` | Plugin installiert, aktualisiert oder entfernt |
